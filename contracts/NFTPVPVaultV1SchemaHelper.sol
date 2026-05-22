// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ApproveAction, FieldDescriptor, VaultMethodSchema, VaultUISchema} from "./flap/IVaultSchemasV1.sol";

contract NFTPVPVaultV1SchemaHelper {
    function vaultUISchema() external pure returns (VaultUISchema memory schema) {
        schema.vaultType = "NFTPVPVaultV1";
        schema.description =
            unicode"NFT PVP Vault 是一个 NFT / Token 双模式 PVP 与双池分红协议。用户每消耗 50,000 Token 可铸造 1 张基础 NFT。10 张基础 NFT 可合成 1 张高级 NFT，高级 NFT 获得 1.2X 分红提升，即 12 倍基础 NFT 分红权重，并拥有永久 VPN 权益。用户可选择使用 Token 或 NFT 参与 PVP，对局由 A 创建、B 加入，匹配后通过 Chainlink VRF 自动开奖。Token 模式胜者获得输家 70% Token，15% Token 销毁，15% Token 进入 LossVault；输家获得最高亏损本金 150% 的 BNB 分红额度。单局最高 2,000,000 Token 等值。交易税 4%，其中 50% 分配给 NFT 持有人，50% 进入 LossVault，分红资产为 BNB。PVP 胜负由 Chainlink VRF 随机数决定，owner / guardian 不能手动决定赢家。";
        schema.methods = new VaultMethodSchema[](13);

        _viewNoInput(schema.methods[0], "getStats", "Vault stats.", _statsOutputs());
        _viewAddressInput(schema.methods[1], "getMyInfo", "Wallet info.", _myInfoOutputs());
        _viewAddressInputSingle(schema.methods[2], "pendingNftDividends", "NFT BNB.", "amount", 18);
        _viewAddressInputSingle(schema.methods[3], "pendingLossDividends", "Loss BNB.", "amount", 18);
        _writeMintNFTByCount(schema.methods[4]);
        _writeMergeBaseNFTs(schema.methods[5]);
        _writeEnterTokenQueue(schema.methods[6]);
        _writeEnterNftQueue(schema.methods[7]);
        _writeLeaveQueue(schema.methods[8]);
        _writeMatchId(schema.methods[9], "settleMatch", "Settle after Chainlink VRF returns randomness.");
        _writeMatchId(schema.methods[10], "emergencyCancelMatch", "After VRF timeout, participants or owner/guardian can cancel; refunds tokens or NFTs with no winner.");
        _writeNoInput(schema.methods[11], "claimNftDividends", "Claim NFT holder BNB rewards.");
        _writeNoInput(
            schema.methods[12],
            "claimLossDividends",
            unicode"输家获得最高亏损本金 150% 的 BNB 分红额度，实际领取取决于 LossVault 收入。"
        );
    }

    function _viewNoInput(
        VaultMethodSchema memory method,
        string memory name,
        string memory methodDescription,
        FieldDescriptor[] memory outputs
    ) private pure {
        method.name = name;
        method.description = methodDescription;
        method.inputs = new FieldDescriptor[](0);
        method.outputs = outputs;
        method.approvals = new ApproveAction[](0);
    }

    function _viewAddressInput(VaultMethodSchema memory method, string memory name, string memory methodDescription, FieldDescriptor[] memory outputs)
        private
        pure
    {
        method.name = name;
        method.description = methodDescription;
        method.inputs = new FieldDescriptor[](1);
        method.inputs[0] = FieldDescriptor("user", "address", "Wallet address to query.", 0);
        method.outputs = outputs;
        method.approvals = new ApproveAction[](0);
    }

    function _viewAddressInputSingle(
        VaultMethodSchema memory method,
        string memory name,
        string memory methodDescription,
        string memory outputName,
        uint8 decimals
    ) private pure {
        FieldDescriptor[] memory outputs = new FieldDescriptor[](1);
        outputs[0] = FieldDescriptor(outputName, "uint256", methodDescription, decimals);
        _viewAddressInput(method, name, methodDescription, outputs);
    }

    function _writeMintNFTByCount(VaultMethodSchema memory method) private pure {
        method.name = "mintNFTByCount";
        method.description =
            unicode"输入 1 = 铸造 1 张基础 NFT，每张消耗 50,000 Token。铸造资金 50% 销毁，25% 进入 LossVault，25% 分红给 NFT 持有人。";
        method.inputs = new FieldDescriptor[](1);
        method.inputs[0] = FieldDescriptor("quantity", "uint256", "NFT quantity.", 0);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](0);
        method.isWriteMethod = true;
    }

    function _writeMergeBaseNFTs(VaultMethodSchema memory method) private pure {
        method.name = "mergeBaseNFTs";
        method.description =
            unicode"10 张基础 NFT 可合成 1 张高级 NFT。合成后原基础 NFT 不再享有分红权，高级 NFT 获得 12 张基础 NFT 的分红权重，并拥有永久 VPN 权益。";
        method.inputs = new FieldDescriptor[](1);
        method.inputs[0] = FieldDescriptor("tokenIds", "uint256[]", "10 base NFT ids.", 0);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](0);
        method.isWriteMethod = true;
    }

    function _writeEnterTokenQueue(VaultMethodSchema memory method) private pure {
        method.name = "enterTokenQueue";
        method.description = unicode"使用 Token 参与 PVP。胜者获得输家 70% Token，15% Token 销毁，15% Token 进入 LossVault。";
        method.inputs = new FieldDescriptor[](2);
        method.inputs[0] = FieldDescriptor("tierId", "uint256", "Tier id.", 0);
        method.inputs[1] = FieldDescriptor("tokenAmount", "uint256", "Tier token amount.", 18);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](1);
        method.approvals[0] = ApproveAction("taxToken", "tokenAmount");
        method.isWriteMethod = true;
    }

    function _writeEnterNftQueue(VaultMethodSchema memory method) private pure {
        method.name = "enterNftQueue";
        method.description = unicode"使用 NFT 参与 PVP。胜者获得输家的 NFT，NFT 不销毁。双方质押 NFT 的 baseUnits 必须相等。";
        method.inputs = new FieldDescriptor[](2);
        method.inputs[0] = FieldDescriptor("tierId", "uint256", "Tier id.", 0);
        method.inputs[1] = FieldDescriptor("nftIds", "uint256[]", "NFT ids.", 0);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](0);
        method.isWriteMethod = true;
    }

    function _writeLeaveQueue(VaultMethodSchema memory method) private pure {
        method.name = "leaveQueue";
        method.description = "Leave unmatched maker queue and unlock/refund your stake.";
        method.inputs = new FieldDescriptor[](1);
        method.inputs[0] = FieldDescriptor("tierId", "uint256", "Tier id.", 0);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](0);
        method.isWriteMethod = true;
    }

    function _writeNoInput(VaultMethodSchema memory method, string memory name, string memory methodDescription) private pure {
        method.name = name;
        method.description = methodDescription;
        method.inputs = new FieldDescriptor[](0);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](0);
        method.isWriteMethod = true;
    }

    function _writeMatchId(VaultMethodSchema memory method, string memory name, string memory methodDescription) private pure {
        method.name = name;
        method.description = methodDescription;
        method.inputs = new FieldDescriptor[](1);
        method.inputs[0] = FieldDescriptor("matchId", "uint256", "Match id.", 0);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](0);
        method.isWriteMethod = true;
    }

    function _statsOutputs() private pure returns (FieldDescriptor[] memory outputs) {
        outputs = new FieldDescriptor[](13);
        outputs[0] = FieldDescriptor("tokenAddress", "address", "Token.", 0);
        outputs[1] = FieldDescriptor("nftAddress", "address", "NFT.", 0);
        outputs[2] = FieldDescriptor("totalMinted", "uint256", "Minted.", 0);
        outputs[3] = FieldDescriptor("liveNftSupply", "uint256", "Live NFTs.", 0);
        outputs[4] = FieldDescriptor("nftMintTokenBuffer", "uint256", "NFT token buffer.", 18);
        outputs[5] = FieldDescriptor("lossMintTokenBuffer", "uint256", "Loss token buffer.", 18);
        outputs[6] = FieldDescriptor("pvpLossTokenBuffer", "uint256", "PVP loss buffer.", 18);
        outputs[7] = FieldDescriptor("nftReservedBnb", "uint256", "NFT BNB.", 18);
        outputs[8] = FieldDescriptor("lossReservedBnb", "uint256", "Loss BNB.", 18);
        outputs[9] = FieldDescriptor("nftUndistributedBnb", "uint256", "NFT pending BNB.", 18);
        outputs[10] = FieldDescriptor("lossUndistributedBnb", "uint256", "Loss pending BNB.", 18);
        outputs[11] = FieldDescriptor("totalLossQuota", "uint256", "Loss quota.", 18);
        outputs[12] = FieldDescriptor("totalBurnedToken", "uint256", "DEAD tokens.", 18);
    }

    function _myInfoOutputs() private pure returns (FieldDescriptor[] memory outputs) {
        outputs = new FieldDescriptor[](5);
        outputs[0] = FieldDescriptor("nftBalance", "uint256", "NFT balance.", 0);
        outputs[1] = FieldDescriptor("pendingNftBnb", "uint256", "NFT BNB.", 18);
        outputs[2] = FieldDescriptor("pendingLossBnb", "uint256", "Loss BNB.", 18);
        outputs[3] = FieldDescriptor("lossQuota", "uint256", "Loss quota.", 18);
        outputs[4] = FieldDescriptor("lossClaimed", "uint256", "Loss claimed.", 18);
    }
}
