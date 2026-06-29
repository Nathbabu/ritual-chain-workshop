// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

/// @title AIJudgeRitualNative (Advanced Track — design sketch)
///
/// @notice This is a design sketch for the advanced track, not a
/// drop-in replacement for AIJudgeCommitReveal. It compiles, but it is not
/// covered by the test suite: the parts that matter most (the TEE executor
/// decrypting ciphertext, and a real DKMS-managed key handshake) only exist
/// on Ritual Chain itself and can't be exercised on a local EVM. Treat the
/// functions below as the contract-side half of the flow described in
/// ARCHITECTURE.md, with the off-chain TEE half documented in prose there.
///
/// Required-track recap of the limitation this fixes: in AIJudgeCommitReveal,
/// answers are still plaintext on-chain for the entire reveal window before
/// judging happens, because revealAnswer() must be its own transaction
/// (mined, and therefore public) ahead of judgeAll(). That window is short
/// and bounded, but it exists. The idea here is to remove it entirely by
/// never putting plaintext on-chain at all, before *or* after the
/// commitment step — only the TEE executor handling judgeAll() ever
/// decrypts anything.
contract AIJudgeRitualNative is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;

    uint256 public nextBountyId = 1;

    struct EncryptedSubmission {
        address submitter;
        // Pointer to the ciphertext sitting off-chain (e.g. "ipfs://..." or
        // "storage-ref://..."). The contract never stores the ciphertext
        // bytes themselves — see ARCHITECTURE.md for why.
        string ciphertextRef;
        // keccak256 of the ciphertext bytes the ref points to. Lets anyone
        // verify the off-chain blob hasn't been swapped after the fact,
        // without the contract ever holding the (large, encrypted) payload.
        bytes32 ciphertextHash;
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline;
        bool judged;
        bool finalized;
        bytes aiReview;
        uint256 winnerIndex;
        // Populated by publishRevealedBundle() *after* judging. Until then
        // both fields are zero/empty, which finalizeWinner() checks for.
        string revealedAnswersRef;
        bytes32 revealedAnswersHash;
        EncryptedSubmission[] submissions;
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    mapping(uint256 => Bounty) public bounties;

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 submissionDeadline
    );

    event EncryptedAnswerSubmitted(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter,
        string ciphertextRef,
        bytes32 ciphertextHash
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event RevealedBundlePublished(
        uint256 indexed bountyId,
        string revealedAnswersRef,
        bytes32 revealedAnswersHash
    );

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submissionDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(
            submissionDeadline > block.timestamp,
            "submission deadline must be in the future"
        );

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];
        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.submissionDeadline = submissionDeadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(bountyId, msg.sender, title, msg.value, submissionDeadline);
    }

    /// @notice Register a pointer + hash to a ciphertext the participant
    /// already encrypted off-chain (for the Ritual TEE executor's
    /// attested public key, via the DKMS precompile flow). No plaintext,
    /// and not even the ciphertext bytes, ever appear in this transaction.
    function submitEncryptedAnswer(
        uint256 bountyId,
        string calldata ciphertextRef,
        bytes32 ciphertextHash
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp < bounty.submissionDeadline, "submission phase over");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bounty.submissions.length < MAX_SUBMISSIONS, "too many submissions");
        require(ciphertextHash != bytes32(0), "empty ciphertext hash");
        require(bytes(ciphertextRef).length > 0, "empty ciphertext ref");

        bounty.submissions.push(
            EncryptedSubmission({
                submitter: msg.sender,
                ciphertextRef: ciphertextRef,
                ciphertextHash: ciphertextHash
            })
        );

        emit EncryptedAnswerSubmitted(
            bountyId,
            bounty.submissions.length - 1,
            msg.sender,
            ciphertextRef,
            ciphertextHash
        );
    }

    /// @notice Same single-batched-call shape as the required track's
    /// judgeAll(). The difference is entirely in how `llmInput` gets built
    /// off-chain: it carries the precompile's `encryptedSecrets` /
    /// `userPublicKey` fields (see web/src/lib/ritualLlm.ts in the
    /// workshop repo) pointing at every submission's ciphertext, so the
    /// TEE executor decrypts all of them as part of *this one* inference
    /// call, batches the plaintexts into a single prompt internally, and
    /// returns one judgment — without this contract, the block builder, or
    /// any other participant ever seeing plaintext.
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.submissionDeadline, "submissions still open");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bounty.submissions.length > 0, "no submissions");

        bytes memory output = _executePrecompile(LLM_INFERENCE_PRECOMPILE, llmInput);

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        bounty.judged = true;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    /// @notice After judging, publish a reference to the full bundle of
    /// now-decrypted plaintext answers (e.g. uploaded to IPFS by the owner,
    /// or by an off-chain job watching for AllAnswersJudged) plus a hash
    /// commitment to that bundle. This is the contract's only commitment to
    /// "what got revealed" — anyone can fetch revealedAnswersRef and check
    /// keccak256(bundleBytes) == revealedAnswersHash without trusting the
    /// owner's word for it. finalizeWinner() refuses to pay out until this
    /// has happened, so a winner can never be chosen from data nobody can
    /// independently verify.
    function publishRevealedBundle(
        uint256 bountyId,
        string calldata revealedAnswersRef,
        bytes32 revealedAnswersHash
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(revealedAnswersHash != bytes32(0), "empty bundle hash");
        require(bytes(revealedAnswersRef).length > 0, "empty bundle ref");

        bounty.revealedAnswersRef = revealedAnswersRef;
        bounty.revealedAnswersHash = revealedAnswersHash;

        emit RevealedBundlePublished(bountyId, revealedAnswersRef, revealedAnswersHash);
    }

    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(bounty.revealedAnswersHash != bytes32(0), "revealed bundle not published yet");
        require(winnerIndex < bounty.submissions.length, "invalid winner index");

        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;

        address winner = bounty.submissions[winnerIndex].submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    function getEncryptedSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (address submitter, string memory ciphertextRef, bytes32 ciphertextHash)
    {
        Bounty storage bounty = bounties[bountyId];
        require(index < bounty.submissions.length, "invalid index");
        EncryptedSubmission storage submission = bounty.submissions[index];
        return (submission.submitter, submission.ciphertextRef, submission.ciphertextHash);
    }
}
