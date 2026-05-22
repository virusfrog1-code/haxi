// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ApproveAction, FieldDescriptor, VaultMethodSchema, VaultUISchema} from "./flap/IVaultSchemasV1.sol";

contract NFTPVPVaultV1SchemaHelper {
    function vaultUISchema() external pure returns (VaultUISchema memory schema) {
        schema.vaultType = unicode"NFT PVP 分红金库";
        schema.description =
            unicode"NFT PVP 分红金库是一个基于 Flap Tax Token 的 NFT 入场券 PVP 与双池分红协议。用户每消耗 100,000 Token 可铸造 1 张 NFT。铸造资金中 50% 自动销毁，25% 进入 LossVault 输家池，25% 分红给 NFT 持有人。持有 NFT 可参与 PVP，对局由 A 进入队列、B 加入同档位后匹配，通过 Chainlink VRF 自动开奖。胜者获得输家 70% Token；15% Token 自动销毁；15% Token 进入 LossVault；输家 NFT 被销毁，并获得最高亏损本金 150% 的 BNB 分红额度。交易税为 4%，其中 50% 分配给 NFT 持有人，50% 进入 LossVault，分红资产为 BNB。NFT 总量 8,888 张，PVP 单局最高 2,000,000 Token。LossVault 是最高额度分红池，不是保证返还，实际领取取决于 LossVault 收入。owner / guardian 不能手动指定赢家。";
        schema.methods = new VaultMethodSchema[](12);

        _viewNoInput(schema.methods[0], "getStats", unicode"查看金库总数据。", _statsOutputs());
        _viewAddressInput(schema.methods[1], "getMyInfo", unicode"查看我的信息。", _myInfoOutputs());
        _viewAddressInputSingle(schema.methods[2], "pendingNftDividends", unicode"查询指定地址可领取的 NFT 持有人 BNB 分红。", unicode"待领取 NFT 分红", 18);
        _viewAddressInputSingle(schema.methods[3], "pendingLossDividends", unicode"查询指定地址可领取的 LossVault BNB 分红。", unicode"待领取 LossVault 分红", 18);
        _writeMintNFTByCount(schema.methods[4]);
        _writeMintNFT(schema.methods[5]);
        _writeEnterQueue(schema.methods[6]);
        _writeLeaveQueue(schema.methods[7]);
        _writeMatchId(schema.methods[8], "settleMatch", unicode"结算对局。当 Chainlink VRF 随机数返回后，可调用此方法完成结算。如果合约已自动结算，则无需手动调用。");
        _writeMatchId(schema.methods[9], "emergencyCancelMatch", unicode"超时取消对局。如果匹配后 VRF 长时间未返回，可在超时后取消对局，双方 Token 和 NFT 退回，不产生输赢。");
        _writeNoInput(schema.methods[10], "claimNftDividends", unicode"领取 NFT 持有人 BNB 分红。每张有效 NFT 拥有相同分红权重。");
        _writeNoInput(schema.methods[11], "claimLossDividends", unicode"领取 LossVault BNB 分红。PVP 输家可领取 LossVault 分红，最高额度为亏损本金的 150%，实际领取取决于 LossVault 收入。");
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

    function _viewAddressInput(
        VaultMethodSchema memory method,
        string memory name,
        string memory methodDescription,
        FieldDescriptor[] memory outputs
    ) private pure {
        method.name = name;
        method.description = methodDescription;
        method.inputs = new FieldDescriptor[](1);
        method.inputs[0] = FieldDescriptor("user", "address", unicode"要查询的钱包地址。", 0);
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
            unicode"铸造 NFT。输入 1 = 铸造 1 张 NFT，每张 NFT 消耗 100,000 Token。铸造资金中 50% 销毁，25% 进入 LossVault，25% 分红给 NFT 持有人。";
        method.inputs = new FieldDescriptor[](1);
        method.inputs[0] = FieldDescriptor("quantity", "uint256", unicode"铸造数量，例如 1、2、10。官网会按 quantity × 100,000 Token 提前完成授权。", 0);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](0);
        method.isWriteMethod = true;
    }

    function _writeMintNFT(VaultMethodSchema memory method) private pure {
        method.name = "mintNFT";
        method.description = unicode"高级铸造入口。按原始 Token 数量铸造 NFT，主要用于高级用户或兼容脚本。普通用户建议使用“铸造 NFT”。";
        method.inputs = new FieldDescriptor[](1);
        method.inputs[0] = FieldDescriptor("tokenAmount", "uint256", unicode"用于铸造的 Token 数量，必须是 100,000 Token 的整数倍。", 18);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](1);
        method.approvals[0] = ApproveAction("taxToken", "tokenAmount");
        method.isWriteMethod = true;
    }

    function _writeEnterQueue(VaultMethodSchema memory method) private pure {
        method.name = "enterQueue";
        method.description =
            unicode"加入 PVP 对赌队列。选择档位后，系统将锁定对应数量 Token 和 1 张 NFT。B 加入同档位后自动匹配成一局，并通过 Chainlink VRF 自动开奖。胜者获得输家 70% Token，15% Token 自动销毁，15% Token 进入 LossVault，输家 NFT 被销毁。";
        method.inputs = new FieldDescriptor[](3);
        method.inputs[0] = FieldDescriptor("tierId", "uint256", unicode"档位编号。0=100,000，1=300,000，2=500,000，3=1,000,000，4=2,000,000 Token。", 0);
        method.inputs[1] = FieldDescriptor("nftId", "uint256", unicode"用于入场的 NFT ID。每局需要锁定 1 张 NFT。", 0);
        method.inputs[2] = FieldDescriptor("tokenAmount", "uint256", unicode"当前档位对应的 Token 数量。", 18);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](1);
        method.approvals[0] = ApproveAction("taxToken", "tokenAmount");
        method.isWriteMethod = true;
    }

    function _writeLeaveQueue(VaultMethodSchema memory method) private pure {
        method.name = "leaveQueue";
        method.description = unicode"退出等待队列。如果尚未匹配成功，可退出队列并取回已锁定的 Token 和 NFT。匹配成功后不能退出，只能等待 VRF 开奖或超时取消。";
        method.inputs = new FieldDescriptor[](1);
        method.inputs[0] = FieldDescriptor("tierId", "uint256", unicode"要退出的档位编号。", 0);
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
        method.inputs[0] = FieldDescriptor("matchId", "uint256", unicode"对局 ID。", 0);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](0);
        method.isWriteMethod = true;
    }

    function _statsOutputs() private pure returns (FieldDescriptor[] memory outputs) {
        outputs = new FieldDescriptor[](13);
        outputs[0] = FieldDescriptor(unicode"代币合约", "address", unicode"Tax Token 合约地址。", 0);
        outputs[1] = FieldDescriptor(unicode"NFT 合约", "address", unicode"PVP NFT 合约地址。", 0);
        outputs[2] = FieldDescriptor(unicode"历史累计铸造 NFT", "uint256", unicode"历史累计铸造 NFT 数量。", 0);
        outputs[3] = FieldDescriptor(unicode"当前存活 NFT", "uint256", unicode"当前仍存活的 NFT 数量，上限为 8,888 张。", 0);
        outputs[4] = FieldDescriptor(unicode"NFT 分红 Token buffer", "uint256", unicode"待兑换进入 NFT 分红池的 Token。", 18);
        outputs[5] = FieldDescriptor(unicode"LossVault 铸造 Token buffer", "uint256", unicode"铸造 NFT 产生、待兑换进入 LossVault 的 Token。", 18);
        outputs[6] = FieldDescriptor(unicode"PVP LossVault Token buffer", "uint256", unicode"PVP 结算产生、待兑换进入 LossVault 的 Token。", 18);
        outputs[7] = FieldDescriptor(unicode"NFT 分红池", "uint256", unicode"已记账给 NFT 持有人的 BNB。", 18);
        outputs[8] = FieldDescriptor(unicode"LossVault 池", "uint256", unicode"已记账给 LossVault 的 BNB。", 18);
        outputs[9] = FieldDescriptor(unicode"NFT 未分配 BNB", "uint256", unicode"暂无 NFT 时暂存的 NFT 分红 BNB。", 18);
        outputs[10] = FieldDescriptor(unicode"LossVault 未分配 BNB", "uint256", unicode"暂无 LossVault quota 时暂存的 LossVault BNB。", 18);
        outputs[11] = FieldDescriptor(unicode"LossVault 总额度", "uint256", unicode"当前有效 LossVault 总额度。", 18);
        outputs[12] = FieldDescriptor(unicode"历史累计销毁 Token", "uint256", unicode"历史累计转入 DEAD 地址的 Token 数量。", 18);
    }

    function _myInfoOutputs() private pure returns (FieldDescriptor[] memory outputs) {
        outputs = new FieldDescriptor[](5);
        outputs[0] = FieldDescriptor(unicode"我的 NFT 数量", "uint256", unicode"当前钱包持有的有效 NFT 数量。", 0);
        outputs[1] = FieldDescriptor(unicode"我的可领取 NFT 分红", "uint256", unicode"当前可领取的 NFT 持有人 BNB 分红。", 18);
        outputs[2] = FieldDescriptor(unicode"我的可领取 LossVault 分红", "uint256", unicode"当前可领取的 LossVault BNB 分红。", 18);
        outputs[3] = FieldDescriptor(unicode"我的 LossVault 总额度", "uint256", unicode"当前钱包有效 LossVault 分红额度。", 18);
        outputs[4] = FieldDescriptor(unicode"我的已领取额度", "uint256", unicode"当前钱包已领取的 LossVault BNB 数量。", 18);
    }
}
