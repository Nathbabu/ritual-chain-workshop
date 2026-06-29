// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;

    function depositFor(address user, uint256 lockDuration) external payable;

    function withdraw(uint256 amount) external;

    function balanceOf(address) external view returns (uint256);

    function lockUntil(address) external view returns (uint256);
}

/// @title AIJudgeCommitReveal
/// @notice Commit-reveal version of the workshop AI Bounty Judge.
///
/// Submissions are hidden during the submission phase: participants only
/// publish keccak256(answer, salt, sender, bountyId) on-chain. Plaintext
/// answers only become public once a participant reveals them, which can
/// only happen after the submission deadline has passed. This removes the
/// "copy the leading answer" exploit that exists in the public version of
/// the contract, where every submission was readable the moment it landed
/// on-chain.
contract AIJudgeCommitReveal is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    IRitualWallet wallet =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    struct Submission {
        address submitter;
        string answer;
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline;
        uint256 revealDeadline;
        bool judged;
        bool finalized;
        bytes aiReview;
        uint256 winnerIndex;
        // Everyone who has submitted a commitment, in submission order.
        // Needed so we can report "N commitments locked in" before any
        // reveal has happened, without ever touching plaintext.
        address[] committers;
        mapping(address => bytes32) commitments;
        mapping(address => bool) hasCommitted;
        mapping(address => bool) hasRevealed;
        // Only successfully-revealed answers end up here. This is the only
        // array judgeAll() and finalizeWinner() ever look at, so an
        // unrevealed (or invalid) submission can never be judged or win.
        Submission[] revealedSubmissions;
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
        uint256 submissionDeadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        address indexed submitter,
        bytes32 commitment
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed revealedIndex,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

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

    /// @notice Create a bounty with a submission phase followed by a reveal
    /// phase. Submissions are accepted while `block.timestamp <
    /// submissionDeadline`; reveals are accepted once the submission
    /// deadline has passed and while `block.timestamp < revealDeadline`.
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(
            submissionDeadline > block.timestamp,
            "submission deadline must be in the future"
        );
        require(
            revealDeadline > submissionDeadline,
            "reveal deadline must be after submission deadline"
        );

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];

        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.submissionDeadline = submissionDeadline;
        bounty.revealDeadline = revealDeadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            submissionDeadline,
            revealDeadline
        );
    }

    /// @notice Submit a hidden commitment to an answer. Only the hash is
    /// stored; the plaintext answer never touches the chain at this point.
    ///
    /// commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(
            block.timestamp < bounty.submissionDeadline,
            "submission phase over"
        );
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(!bounty.hasCommitted[msg.sender], "already committed");
        require(commitment != bytes32(0), "empty commitment");
        require(
            bounty.committers.length < MAX_SUBMISSIONS,
            "too many submissions"
        );

        bounty.hasCommitted[msg.sender] = true;
        bounty.commitments[msg.sender] = commitment;
        bounty.committers.push(msg.sender);

        emit CommitmentSubmitted(bountyId, msg.sender, commitment);
    }

    /// @notice Reveal a previously committed answer. Reverts unless the
    /// recomputed hash matches the stored commitment exactly, which means a
    /// participant can never reveal someone else's answer: msg.sender is
    /// baked into the hash, so copying another committer's hash and
    /// resubmitting it under a different address will not produce a
    /// matching reveal.
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(
            block.timestamp >= bounty.submissionDeadline,
            "reveal phase not started"
        );
        require(block.timestamp < bounty.revealDeadline, "reveal phase over");
        require(bounty.hasCommitted[msg.sender], "no commitment found");
        require(!bounty.hasRevealed[msg.sender], "already revealed");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        bytes32 expected = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );
        require(expected == bounty.commitments[msg.sender], "commitment mismatch");

        bounty.hasRevealed[msg.sender] = true;
        bounty.revealedSubmissions.push(
            Submission({submitter: msg.sender, answer: answer})
        );

        emit AnswerRevealed(
            bountyId,
            bounty.revealedSubmissions.length - 1,
            msg.sender
        );
    }

    /// @notice Send every revealed answer to the Ritual LLM precompile in a
    /// single batched request. Only callable once the reveal window has
    /// closed, so judging can never see an answer that a competitor could
    /// still copy.
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(
            block.timestamp >= bounty.revealDeadline,
            "reveal phase not over"
        );
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bounty.revealedSubmissions.length > 0, "no revealed submissions");

        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

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

    /// @notice Owner-controlled finalization. The AI's output (`aiReview`)
    /// is advisory; the owner still has to read it and pass in the winning
    /// index explicitly, so a malformed or adversarial model response can
    /// never move funds on its own.
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(
            winnerIndex < bounty.revealedSubmissions.length,
            "invalid winner index"
        );

        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;

        address winner = bounty.revealedSubmissions[winnerIndex].submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    function getBounty(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 submissionDeadline,
            uint256 revealDeadline,
            bool judged,
            bool finalized
        )
    {
        Bounty storage bounty = bounties[bountyId];

        return (
            bounty.owner,
            bounty.title,
            bounty.rubric,
            bounty.reward,
            bounty.submissionDeadline,
            bounty.revealDeadline,
            bounty.judged,
            bounty.finalized
        );
    }

    /// @notice Split out from `getBounty` to avoid a "stack too deep" error
    /// from returning too many values out of a single function.
    function getBountyResult(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            uint256 commitmentCount,
            uint256 revealedCount,
            uint256 winnerIndex,
            bytes memory aiReview
        )
    {
        Bounty storage bounty = bounties[bountyId];

        return (
            bounty.committers.length,
            bounty.revealedSubmissions.length,
            bounty.winnerIndex,
            bounty.aiReview
        );
    }

    /// @notice Plaintext answers are intentionally NOT exposed here until
    /// they have been revealed; this only ever reads from
    /// `revealedSubmissions`, which is empty for anything still hidden.
    function getRevealedSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (address submitter, string memory answer)
    {
        Bounty storage bounty = bounties[bountyId];

        require(index < bounty.revealedSubmissions.length, "invalid index");

        Submission storage submission = bounty.revealedSubmissions[index];

        return (submission.submitter, submission.answer);
    }

    function getCommitter(
        uint256 bountyId,
        uint256 index
    ) external view bountyExists(bountyId) returns (address) {
        Bounty storage bounty = bounties[bountyId];
        require(index < bounty.committers.length, "invalid index");
        return bounty.committers[index];
    }

    function getCommitmentStatus(
        uint256 bountyId,
        address participant
    )
        external
        view
        bountyExists(bountyId)
        returns (bool hasCommitted, bool hasRevealed, bytes32 commitment)
    {
        Bounty storage bounty = bounties[bountyId];
        return (
            bounty.hasCommitted[participant],
            bounty.hasRevealed[participant],
            bounty.commitments[participant]
        );
    }
}
