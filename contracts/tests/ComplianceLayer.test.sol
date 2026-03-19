// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// ============================================================================
// ComplianceLayer.test.sol
// Comprehensive test suite for ComplianceLayer.sol
// Compatible with Foundry (forge test)
// ============================================================================

import "forge-std/Test.sol";
import "../ComplianceLayer.sol";

contract ComplianceLayerTest is Test {
    ComplianceLayer internal cl;

    address internal admin      = address(0xCC01);
    address internal timelock   = address(0xCC02);
    address internal kycOfficer = address(0xCC03);
    address internal amlOfficer = address(0xCC04);
    address internal auditor    = address(0xCC05);
    address internal alice      = address(0xCC06);
    address internal bob        = address(0xCC07);
    address internal carol      = address(0xCC08);

    function setUp() public {
        ComplianceLayer impl = new ComplianceLayer();
        vm.prank(admin);
        impl.initialize(timelock, admin);
        cl = impl;

        // Grant roles
        vm.startPrank(admin);
        cl.grantRole(cl.KYC_OFFICER_ROLE(), kycOfficer);
        cl.grantRole(cl.AML_OFFICER_ROLE(), amlOfficer);
        cl.grantRole(cl.AUDITOR_ROLE(),     auditor);
        vm.stopPrank();
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _approveAlice() internal {
        vm.prank(kycOfficer);
        cl.onboardUser(alice, ICompliance.KYCStatus.Approved, "ProviderA", block.timestamp + 365 days);
    }

    function _approveBob() internal {
        vm.prank(kycOfficer);
        cl.onboardUser(bob, ICompliance.KYCStatus.Approved, "ProviderA", block.timestamp + 365 days);
    }

    // =========================================================================
    // 1. KYC Onboarding & Verification
    // =========================================================================

    function test_OnboardUser_Success() public {
        _approveAlice();
        ICompliance.UserRecord memory rec = cl.getUserRecord(alice);
        assertEq(uint8(rec.kycStatus), uint8(ICompliance.KYCStatus.Approved));
        assertEq(rec.kycProvider, "ProviderA");
    }

    function test_OnboardUser_NotOfficer_Reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        cl.onboardUser(alice, ICompliance.KYCStatus.Approved, "P", block.timestamp + 1);
    }

    function test_OnboardUser_Duplicate_Reverts() public {
        _approveAlice();
        vm.prank(kycOfficer);
        vm.expectRevert("Already onboarded");
        cl.onboardUser(alice, ICompliance.KYCStatus.Approved, "P", block.timestamp + 1);
    }

    function test_UpdateKYCStatus_ToRejected() public {
        _approveAlice();
        vm.prank(kycOfficer);
        cl.updateKYCStatus(alice, ICompliance.KYCStatus.Rejected, "ProviderB", block.timestamp + 1);

        ICompliance.UserRecord memory rec = cl.getUserRecord(alice);
        assertEq(uint8(rec.kycStatus), uint8(ICompliance.KYCStatus.Rejected));
    }

    function test_UpdateKYCStatus_NotOfficer_Reverts() public {
        _approveAlice();
        vm.prank(alice);
        vm.expectRevert();
        cl.updateKYCStatus(alice, ICompliance.KYCStatus.Rejected, "P", block.timestamp + 1);
    }

    // =========================================================================
    // 2. AML Risk Level
    // =========================================================================

    function test_UpdateRiskLevel_ToHigh() public {
        _approveAlice();
        vm.prank(amlOfficer);
        cl.updateRiskLevel(alice, ICompliance.RiskLevel.High);

        ICompliance.UserRecord memory rec = cl.getUserRecord(alice);
        assertEq(uint8(rec.riskLevel), uint8(ICompliance.RiskLevel.High));
    }

    function test_UpdateRiskLevel_NotAMLOfficer_Reverts() public {
        _approveAlice();
        vm.prank(alice);
        vm.expectRevert();
        cl.updateRiskLevel(alice, ICompliance.RiskLevel.High);
    }

    // =========================================================================
    // 3. Account Freezing / Emergency Controls
    // =========================================================================

    function test_FreezeAccount_Success() public {
        _approveAlice();
        vm.prank(amlOfficer);
        cl.freezeAccount(alice, "Suspicious activity");

        assertTrue(cl.isFrozen(alice));
    }

    function test_FreezeAccount_NotAMLOfficer_Reverts() public {
        _approveAlice();
        vm.prank(alice);
        vm.expectRevert();
        cl.freezeAccount(alice, "reason");
    }

    function test_UnfreezeAccount_Success() public {
        _approveAlice();

        vm.prank(amlOfficer);
        cl.freezeAccount(alice, "Precaution");

        vm.prank(amlOfficer);
        cl.unfreezeAccount(alice, "Cleared");

        assertFalse(cl.isFrozen(alice));
    }

    function test_FrozenAccount_BlocksTransaction() public {
        _approveAlice();

        vm.prank(amlOfficer);
        cl.freezeAccount(alice, "AML hold");

        vm.prank(address(this));
        (bool approved, string memory reason) = cl.previewScreen(alice, 100e18);
        assertFalse(approved);
        assertEq(keccak256(bytes(reason)), keccak256(bytes("Account frozen")));
    }

    // =========================================================================
    // 4. Transaction Screening
    // =========================================================================

    function test_ScreenTransaction_ApprovedUser_Passes() public {
        _approveAlice();

        vm.prank(address(this));
        bool approved = cl.screenTransaction(alice, 100e18, bytes32("tx1"));
        assertTrue(approved);
    }

    function test_ScreenTransaction_NotKYC_Blocked() public {
        // Carol not onboarded
        (bool approved, string memory reason) = cl.previewScreen(carol, 1e18);
        assertFalse(approved);
        assertEq(keccak256(bytes(reason)), keccak256(bytes("KYC not approved")));
    }

    function test_ScreenTransaction_Sanctioned_Blocked() public {
        _approveAlice();

        vm.prank(amlOfficer);
        cl.setSanctioned(alice, true);

        (bool approved, string memory reason) = cl.previewScreen(alice, 1e18);
        assertFalse(approved);
        assertEq(keccak256(bytes(reason)), keccak256(bytes("Sanctioned address")));
    }

    function test_ScreenTransaction_ExpiredKYC_Blocked() public {
        vm.prank(kycOfficer);
        cl.onboardUser(alice, ICompliance.KYCStatus.Approved, "P", block.timestamp + 10);

        // Warp past expiry
        vm.warp(block.timestamp + 20);

        (bool approved, string memory reason) = cl.previewScreen(alice, 1e18);
        assertFalse(approved);
        assertEq(keccak256(bytes(reason)), keccak256(bytes("KYC expired")));
    }

    function test_ScreenTransaction_BlockedRiskLevel_Blocked() public {
        _approveAlice();

        vm.prank(amlOfficer);
        cl.updateRiskLevel(alice, ICompliance.RiskLevel.Blocked);

        (bool approved, string memory reason) = cl.previewScreen(alice, 1e18);
        assertFalse(approved);
        assertEq(keccak256(bytes(reason)), keccak256(bytes("High-risk account blocked")));
    }

    // =========================================================================
    // 5. Compliance Rules
    // =========================================================================

    function test_AddRule_And_EnforceMaxTxAmount() public {
        _approveAlice();

        ICompliance.ComplianceRule memory rule = ICompliance.ComplianceRule({
            id: keccak256("RULE_MAX_TX"),
            name: "MaxTxLimit",
            maxDailyVolume: 0,
            maxTxAmount: 500e18,
            minRiskLevel: ICompliance.RiskLevel.Blocked,
            requiresKYC: true,
            active: true
        });

        vm.prank(admin);
        cl.addRule(rule);

        (bool approved, string memory reason) = cl.previewScreen(alice, 1_000e18);
        assertFalse(approved);
        assertEq(keccak256(bytes(reason)), keccak256(bytes("Exceeds max transaction limit")));
    }

    function test_AddRule_Duplicate_Reverts() public {
        ICompliance.ComplianceRule memory rule = ICompliance.ComplianceRule({
            id: keccak256("RULE_DUPE"),
            name: "DupeRule",
            maxDailyVolume: 0,
            maxTxAmount: 0,
            minRiskLevel: ICompliance.RiskLevel.Blocked,
            requiresKYC: false,
            active: true
        });

        vm.startPrank(admin);
        cl.addRule(rule);
        vm.expectRevert("Rule already exists");
        cl.addRule(rule);
        vm.stopPrank();
    }

    function test_RemoveRule_Success() public {
        bytes32 ruleId = keccak256("RULE_REM");
        ICompliance.ComplianceRule memory rule = ICompliance.ComplianceRule({
            id: ruleId,
            name: "RemoveMe",
            maxDailyVolume: 0,
            maxTxAmount: 1e18,
            minRiskLevel: ICompliance.RiskLevel.Blocked,
            requiresKYC: false,
            active: true
        });

        vm.startPrank(admin);
        cl.addRule(rule);
        cl.removeRule(ruleId);
        vm.stopPrank();

        // After removal, the 1e18 limit should no longer block 2e18
        _approveAlice();
        (bool approved, ) = cl.previewScreen(alice, 2e18);
        assertTrue(approved);
    }

    // =========================================================================
    // 6. Sanctions List
    // =========================================================================

    function test_SetSanctioned_And_Check() public {
        vm.prank(amlOfficer);
        cl.setSanctioned(bob, true);

        assertTrue(cl.isSanctioned(bob));

        vm.prank(amlOfficer);
        cl.setSanctioned(bob, false);

        assertFalse(cl.isSanctioned(bob));
    }

    // =========================================================================
    // 7. Regulatory Reporting
    // =========================================================================

    function test_GenerateReport_ByAuditor() public {
        _approveAlice();

        // Generate some activity
        vm.prank(address(this));
        cl.screenTransaction(alice, 100e18, bytes32("tx1"));

        vm.prank(auditor);
        ICompliance.ComplianceReport memory report = cl.generateReport(0, block.timestamp);

        assertGt(report.totalTransactions, 0);
        assertGt(report.totalVolume, 0);
    }

    function test_GenerateReport_NotAuditor_Reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        cl.generateReport(0, block.timestamp);
    }

    // =========================================================================
    // 8. Pause / Unpause
    // =========================================================================

    function test_Pause_BlocksScreening() public {
        _approveAlice();

        vm.prank(admin);
        cl.pause();

        vm.prank(address(this));
        vm.expectRevert();
        cl.screenTransaction(alice, 10e18, bytes32("tx"));
    }

    function test_Unpause_AllowsScreening() public {
        _approveAlice();

        vm.prank(admin);
        cl.pause();

        vm.prank(admin);
        cl.unpause();

        vm.prank(address(this));
        bool ok = cl.screenTransaction(alice, 10e18, bytes32("tx"));
        assertTrue(ok);
    }
}
