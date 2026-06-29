// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AIJudgeCommitReveal} from "./AIJudgeCommitReveal.sol";

/// @notice Solidity test suite for AIJudgeCommitReveal.
///
/// The LLM inference precompile (0x0802) doesn't exist on a plain local EVM,
/// so every test that reaches `judgeAll` stubs it out with `vm.mockCall`.
/// The mock is registered with empty `data`, which Foundry treats as a
/// wildcard prefix match, so it intercepts the call regardless of the actual
/// `llmInput` bytes passed in. This mirrors how the contract is used in
/// practice: judgeAll() never inspects llmInput itself, it just forwards it.
contract AIJudgeCommitRevealTest is Test {
    address constant LLM_INFERENCE_PRECOMPILE = address(0x0802);

    AIJudgeCommitReveal judge;

    address owner = address(0xA11CE);
    address alice = address(0xA1);
    address bob = address(0xB0B);
    address mallory = address(0xBAD);

    uint256 constant REWARD = 1 ether;
    string constant TITLE = "Best Solidity Optimization";
    string constant RUBRIC = "Judge by gas efficiency and clarity";

    uint256 submissionDeadline;
    uint256 revealDeadline;

    function setUp() public {
        judge = new AIJudgeCommitReveal();

        vm.deal(owner, 10 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(mallory, 10 ether);

        submissionDeadline = block.timestamp + 1 days;
        revealDeadline = submissionDeadline + 1 days;
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _commitment(
        string memory answer,
        bytes32 salt,
        address who,
        uint256 bountyId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, who, bountyId));
    }

    function _createBounty() internal returns (uint256 bountyId) {
        vm.prank(owner);
        bountyId = judge.createBounty{value: REWARD}(
            TITLE,
            RUBRIC,
            submissionDeadline,
            revealDeadline
        );
    }

    /// Stubs the LLM precompile so judgeAll() succeeds. The completion
    /// text itself is just stored as `aiReview`; the contract never parses
    /// it, so its contents don't matter for these tests.
    function _mockLlmSuccess() internal {
        bytes memory completionData = bytes('{"winnerIndex":0,"summary":"ok"}');
        AIJudgeCommitReveal.ConvoHistory memory convo = AIJudgeCommitReveal
            .ConvoHistory("", "", "");
        bytes memory actualOutput = abi.encode(
            false, // hasError
            completionData,
            bytes(""),
            "", // errorMessage
            convo
        );
        bytes memory rawOutput = abi.encode(bytes(""), actualOutput);
        vm.mockCall(LLM_INFERENCE_PRECOMPILE, "", rawOutput);
    }

    function _mockLlmError(string memory message) internal {
        AIJudgeCommitReveal.ConvoHistory memory convo = AIJudgeCommitReveal
            .ConvoHistory("", "", "");
        bytes memory actualOutput = abi.encode(
            true, // hasError
            bytes(""),
            bytes(""),
            message,
            convo
        );
        bytes memory rawOutput = abi.encode(bytes(""), actualOutput);
        vm.mockCall(LLM_INFERENCE_PRECOMPILE, "", rawOutput);
    }

    // ------------------------------------------------------------------
    // Happy path
    // ------------------------------------------------------------------

    function test_RevealsOnlyCountAfterRevealPhase() public {
        uint256 bountyId = _createBounty();

        bytes32 saltAlice = keccak256("alice-salt");
        bytes32 commitAlice = _commitment("alice answer", saltAlice, alice, bountyId);

        vm.prank(alice);
        judge.submitCommitment(bountyId, commitAlice);

        (uint256 commitmentCount, uint256 revealedCount, , ) = judge.getBountyResult(bountyId);
        assertEq(commitmentCount, 1);
        assertEq(revealedCount, 0);

        vm.warp(submissionDeadline + 1);

        vm.prank(alice);
        judge.revealAnswer(bountyId, "alice answer", saltAlice);

        (, uint256 revealedCountAfter, , ) = judge.getBountyResult(bountyId);
        assertEq(revealedCountAfter, 1);
    }

    function test_FullLifecycle_WinnerGetsPaid() public {
        uint256 bountyId = _createBounty();

        bytes32 saltAlice = keccak256("alice-salt");
        bytes32 saltBob = keccak256("bob-salt");

        vm.prank(alice);
        judge.submitCommitment(
            bountyId,
            _commitment("alice answer", saltAlice, alice, bountyId)
        );

        vm.prank(bob);
        judge.submitCommitment(
            bountyId,
            _commitment("bob answer", saltBob, bob, bountyId)
        );

        vm.warp(submissionDeadline + 1);

        vm.prank(alice);
        judge.revealAnswer(bountyId, "alice answer", saltAlice);

        vm.prank(bob);
        judge.revealAnswer(bountyId, "bob answer", saltBob); // revealed index 1

        vm.warp(revealDeadline + 1);

        _mockLlmSuccess();

        vm.prank(owner);
        judge.judgeAll(bountyId, hex"1234");

        uint256 bobBalanceBefore = bob.balance;

        vm.prank(owner);
        judge.finalizeWinner(bountyId, 1);

        assertEq(bob.balance, bobBalanceBefore + REWARD);

        (, , , , , , bool judged, bool finalized) = judge.getBounty(bountyId);
        assertTrue(judged);
        assertTrue(finalized);

        (, , uint256 winnerIndex, ) = judge.getBountyResult(bountyId);
        assertEq(winnerIndex, 1);
    }

    // ------------------------------------------------------------------
    // Commitment phase rules
    // ------------------------------------------------------------------

    function test_RevertWhen_CommitAfterSubmissionDeadline() public {
        uint256 bountyId = _createBounty();
        vm.warp(submissionDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("submission phase over"));
        judge.submitCommitment(bountyId, keccak256("anything"));
    }

    function test_RevertWhen_DuplicateCommitment() public {
        uint256 bountyId = _createBounty();

        vm.prank(alice);
        judge.submitCommitment(bountyId, keccak256("first"));

        vm.prank(alice);
        vm.expectRevert(bytes("already committed"));
        judge.submitCommitment(bountyId, keccak256("second"));
    }

    function test_RevertWhen_EmptyCommitment() public {
        uint256 bountyId = _createBounty();

        vm.prank(alice);
        vm.expectRevert(bytes("empty commitment"));
        judge.submitCommitment(bountyId, bytes32(0));
    }

    // ------------------------------------------------------------------
    // Reveal phase rules
    // ------------------------------------------------------------------

    function test_RevertWhen_RevealDuringSubmissionPhase() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("salt");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("answer", salt, alice, bountyId));

        // still before submissionDeadline
        vm.prank(alice);
        vm.expectRevert(bytes("reveal phase not started"));
        judge.revealAnswer(bountyId, "answer", salt);
    }

    function test_RevertWhen_RevealAfterRevealDeadline() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("salt");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("answer", salt, alice, bountyId));

        vm.warp(revealDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("reveal phase over"));
        judge.revealAnswer(bountyId, "answer", salt);
    }

    function test_RevertWhen_RevealWithoutCommitment() public {
        uint256 bountyId = _createBounty();
        vm.warp(submissionDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("no commitment found"));
        judge.revealAnswer(bountyId, "answer", keccak256("salt"));
    }

    function test_RevertWhen_RevealHashMismatch_WrongAnswer() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("salt");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("answer", salt, alice, bountyId));

        vm.warp(submissionDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("commitment mismatch"));
        judge.revealAnswer(bountyId, "a different answer", salt);
    }

    function test_RevertWhen_RevealHashMismatch_WrongSalt() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("salt");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("answer", salt, alice, bountyId));

        vm.warp(submissionDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("commitment mismatch"));
        judge.revealAnswer(bountyId, "answer", keccak256("wrong salt"));
    }

    function test_RevertWhen_DoubleReveal() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("salt");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("answer", salt, alice, bountyId));

        vm.warp(submissionDeadline + 1);

        vm.prank(alice);
        judge.revealAnswer(bountyId, "answer", salt);

        vm.prank(alice);
        vm.expectRevert(bytes("already revealed"));
        judge.revealAnswer(bountyId, "answer", salt);
    }

    /// This is the specific fairness property the homework calls out:
    /// msg.sender is baked into the commitment hash, so a participant who
    /// copies someone else's commitment as their own cannot later reveal
    /// that person's answer under their own address.
    function test_CannotCopyAnothersCommitmentAndReveal() public {
        uint256 bountyId = _createBounty();
        bytes32 saltAlice = keccak256("alice-salt");
        bytes32 aliceCommitment = _commitment("alice's great answer", saltAlice, alice, bountyId);

        vm.prank(alice);
        judge.submitCommitment(bountyId, aliceCommitment);

        // Mallory sees Alice's commitment hash on-chain and resubmits the
        // exact same hash as her own commitment, hoping to later reveal the
        // same answer/salt pair and pass it off as her own submission.
        vm.prank(mallory);
        judge.submitCommitment(bountyId, aliceCommitment);

        vm.warp(submissionDeadline + 1);

        // Alice reveals normally and succeeds.
        vm.prank(alice);
        judge.revealAnswer(bountyId, "alice's great answer", saltAlice);

        // Mallory tries to reveal the same answer/salt under her own
        // address. Because msg.sender is part of the hash, the recomputed
        // commitment for Mallory does not match what she committed.
        vm.prank(mallory);
        vm.expectRevert(bytes("commitment mismatch"));
        judge.revealAnswer(bountyId, "alice's great answer", saltAlice);
    }

    function test_UnrevealedCommitmentIsNotEligibleForJudging() public {
        uint256 bountyId = _createBounty();
        bytes32 saltAlice = keccak256("alice-salt");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("alice answer", saltAlice, alice, bountyId));

        // Bob commits but never reveals.
        vm.prank(bob);
        judge.submitCommitment(bountyId, keccak256("bob never reveals this"));

        vm.warp(submissionDeadline + 1);

        vm.prank(alice);
        judge.revealAnswer(bountyId, "alice answer", saltAlice);

        vm.warp(revealDeadline + 1);

        (uint256 commitmentCount, uint256 revealedCount, , ) = judge.getBountyResult(bountyId);
        assertEq(commitmentCount, 2);
        assertEq(revealedCount, 1); // only Alice's revealed answer is eligible

        _mockLlmSuccess();

        vm.prank(owner);
        judge.judgeAll(bountyId, hex"1234");

        // Only index 0 (Alice) exists among revealed submissions.
        vm.prank(owner);
        vm.expectRevert(bytes("invalid winner index"));
        judge.finalizeWinner(bountyId, 1);
    }

    // ------------------------------------------------------------------
    // Judging / finalization rules
    // ------------------------------------------------------------------

    function test_RevertWhen_JudgeBeforeRevealDeadlineOver() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("salt");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("answer", salt, alice, bountyId));

        vm.warp(submissionDeadline + 1);

        vm.prank(alice);
        judge.revealAnswer(bountyId, "answer", salt);

        // still inside the reveal window
        vm.prank(owner);
        vm.expectRevert(bytes("reveal phase not over"));
        judge.judgeAll(bountyId, hex"1234");
    }

    function test_RevertWhen_JudgeWithNoRevealedSubmissions() public {
        uint256 bountyId = _createBounty();
        vm.warp(revealDeadline + 1);

        vm.prank(owner);
        vm.expectRevert(bytes("no revealed submissions"));
        judge.judgeAll(bountyId, hex"1234");
    }

    function test_RevertWhen_NonOwnerCallsJudgeAll() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("salt");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("answer", salt, alice, bountyId));

        vm.warp(revealDeadline + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("not bounty owner"));
        judge.judgeAll(bountyId, hex"1234");
    }

    function test_RevertWhen_JudgeAllPropagatesLlmError() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("salt");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("answer", salt, alice, bountyId));

        vm.warp(submissionDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(bountyId, "answer", salt);

        vm.warp(revealDeadline + 1);

        _mockLlmError("model unavailable");

        vm.prank(owner);
        vm.expectRevert(bytes("model unavailable"));
        judge.judgeAll(bountyId, hex"1234");
    }

    function test_RevertWhen_FinalizeBeforeJudged() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("salt");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("answer", salt, alice, bountyId));

        vm.warp(submissionDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(bountyId, "answer", salt);

        vm.warp(revealDeadline + 1);

        vm.prank(owner);
        vm.expectRevert(bytes("not judged yet"));
        judge.finalizeWinner(bountyId, 0);
    }

    function test_RevertWhen_NonOwnerFinalizes() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("salt");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("answer", salt, alice, bountyId));

        vm.warp(submissionDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(bountyId, "answer", salt);

        vm.warp(revealDeadline + 1);
        _mockLlmSuccess();
        vm.prank(owner);
        judge.judgeAll(bountyId, hex"1234");

        vm.prank(mallory);
        vm.expectRevert(bytes("not bounty owner"));
        judge.finalizeWinner(bountyId, 0);
    }

    function test_RevertWhen_DoubleFinalize() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("salt");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("answer", salt, alice, bountyId));

        vm.warp(submissionDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(bountyId, "answer", salt);

        vm.warp(revealDeadline + 1);
        _mockLlmSuccess();
        vm.prank(owner);
        judge.judgeAll(bountyId, hex"1234");

        vm.prank(owner);
        judge.finalizeWinner(bountyId, 0);

        vm.prank(owner);
        vm.expectRevert(bytes("already finalized"));
        judge.finalizeWinner(bountyId, 0);
    }

    function test_RevertWhen_DoubleJudge() public {
        uint256 bountyId = _createBounty();
        bytes32 salt = keccak256("salt");

        vm.prank(alice);
        judge.submitCommitment(bountyId, _commitment("answer", salt, alice, bountyId));

        vm.warp(submissionDeadline + 1);
        vm.prank(alice);
        judge.revealAnswer(bountyId, "answer", salt);

        vm.warp(revealDeadline + 1);
        _mockLlmSuccess();
        vm.prank(owner);
        judge.judgeAll(bountyId, hex"1234");

        vm.prank(owner);
        vm.expectRevert(bytes("already judged"));
        judge.judgeAll(bountyId, hex"5678");
    }

    // ------------------------------------------------------------------
    // Bounty creation rules
    // ------------------------------------------------------------------

    function test_RevertWhen_RewardIsZero() public {
        vm.prank(owner);
        vm.expectRevert(bytes("reward required"));
        judge.createBounty(TITLE, RUBRIC, submissionDeadline, revealDeadline);
    }

    function test_RevertWhen_RevealDeadlineNotAfterSubmissionDeadline() public {
        vm.prank(owner);
        vm.expectRevert(bytes("reveal deadline must be after submission deadline"));
        judge.createBounty{value: REWARD}(
            TITLE,
            RUBRIC,
            submissionDeadline,
            submissionDeadline
        );
    }
}
