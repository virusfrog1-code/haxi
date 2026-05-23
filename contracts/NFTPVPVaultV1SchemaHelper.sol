// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ApproveAction, FieldDescriptor, VaultMethodSchema, VaultUISchema} from "./flap/IVaultSchemasV1.sol";

contract NFTPVPVaultV1SchemaHelper {
    function vaultUISchema() external pure returns (VaultUISchema memory schema) {
        schema.vaultType = unicode"NFT PVP 多人 Round 分红金库";
        schema.description =
            unicode"NFT PVP 分红金库采用同档位多人 Round 机制。用户选择档位并质押对应 Token 和 1 张 NFT 后加入当前轮。第一位用户加入后开始 5 分钟倒计时，倒计时内同档位用户均可加入。倒计时结束后，任何人可触发 Chainlink VRF 公平开奖，项目方不能决定赢家。本轮只产生 1 名唯一赢家，赢家获得所有输家的 70% Token；所有输家的 15% Token 销毁，15% Token 进入 LossVault，输家 NFT 被销毁，并获得最高亏损本金 150% 的 BNB 分红额度。NFT 进入 Round 后暂停分红，退出或获胜后恢复分红。交易税 4%，其中 50% 分配给 NFT 持有人，50% 进入 LossVault。LossVault 不是保证返还，实际领取取决于池子收入。";
        schema.methods = new VaultMethodSchema[](21);

        _viewNoInput(schema.methods[0], "getStats", unicode"查看金库总数据、Round 数据、NFT 分红、LossVault 额度、累计销毁和各档位等待人数。", _statsOutputs());
        _viewAddressInput(schema.methods[1], "getMyInfo", unicode"查看指定用户的 NFT、LossVault、当前 Round、胜负场次、剩余额度和当前可领取信息。", _myInfoOutputs());
        _viewAddressInputSingle(schema.methods[2], "pendingNftDividends", unicode"查询指定地址可领取的 NFT 持有人 BNB 分红。", unicode"待领取 NFT 分红", 18);
        _viewAddressInputSingle(schema.methods[3], "pendingLossDividends", unicode"查询指定地址可领取的 LossVault BNB 分红。", unicode"待领取 LossVault 分红", 18);
        _writeNoInput(schema.methods[4], "mint1NFT", unicode"铸造 1 张 NFT。每张 NFT 消耗 100,000 Token。NFT 是参与 PVP 的入场门票。铸造资金中 50% 销毁，25% 进入 LossVault，25% 分红给 NFT 持有人。");
        _writeNoInput(schema.methods[5], "mint2NFT", unicode"铸造 2 张 NFT，共消耗 200,000 Token。NFT 是 PVP 入场门票。");
        _writeNoInput(schema.methods[6], "mint5NFT", unicode"铸造 5 张 NFT，共消耗 500,000 Token。NFT 是 PVP 入场门票。");
        _writeNoInput(schema.methods[7], "mint10NFT", unicode"铸造 10 张 NFT，共消耗 1,000,000 Token。NFT 是 PVP 入场门票。");
        _writeMintNFTByCount(schema.methods[8]);
        _writeEnterQueue(schema.methods[9]);
        _writeTierInput(schema.methods[10], "leaveQueue", unicode"退出等待中的 Round。只有 Round 仍在 5 分钟倒计时内且未请求 VRF 时可退出，退出后 Token 和 NFT 退回，NFT 恢复分红。");
        _writeRoundId(schema.methods[11], "requestRoundRandomness", unicode"请求 Chainlink VRF 开奖。Round 倒计时结束且至少 2 人参与后，任何人都可以调用。项目方不能指定赢家。");
        _writeRoundId(schema.methods[12], "settleRound", unicode"结算 Round。当 Chainlink VRF 随机数返回后，任何人都可以调用。若随机数未返回，会提示 RoundRandomNotReady。");
        _writeRoundId(schema.methods[13], "emergencyCancelRound", unicode"超时取消 Round。单人 Round 倒计时结束后可取消；VRF 长时间未返回时参与者可取消。取消后 Token 和 NFT 退回，不产生输赢或 LossVault 额度。");
        _writeNoInput(schema.methods[14], "claimNftDividends", unicode"领取 NFT 持有人 BNB 分红。Round 中的 NFT 暂停分红，退出或获胜后恢复分红。连续领取不会 underflow。");
        _writeNoInput(schema.methods[15], "claimLossDividends", unicode"领取 LossVault BNB 分红。PVP 输家最高获得亏损本金 150% 的额度，实际领取取决于 LossVault 收入。");
        _viewUintInput(schema.methods[16], "getRound", unicode"查看 Round 状态、参与人数、截止时间、是否可请求 VRF、是否可结算、是否可取消。", _roundOutputs(), "roundId", unicode"Round ID。");
        _viewUintInput(schema.methods[17], "getCurrentRound", unicode"查看指定档位当前开放的 Round。档位：0=100,000，1=500,000，2=2,000,000，3=5,000,000，4=10,000,000 Token。", _roundOutputs(), "tierId", unicode"档位编号。");
        _viewUintInput(schema.methods[18], "canRequestRoundRandomness", unicode"查询指定 Round 是否已经满足请求 Chainlink VRF 开奖条件。", _boolOutput(unicode"是否可请求 VRF", unicode"倒计时结束且至少 2 人参与，或达到最大人数时为 true。"), "roundId", unicode"Round ID。");
        _viewUintInput(schema.methods[19], "canSettleRound", unicode"查询指定 Round 是否已经收到 Chainlink VRF 随机数并可结算。", _boolOutput(unicode"是否可结算", unicode"VRF 随机数已返回时为 true。"), "roundId", unicode"Round ID。");
        _viewUintInput(schema.methods[20], "canEmergencyCancelRound", unicode"查询指定 Round 是否可以超时取消。", _boolOutput(unicode"是否可取消", unicode"单人 Round 到期或 VRF 超时未返回时为 true。"), "roundId", unicode"Round ID。");
    }

    function _viewNoInput(VaultMethodSchema memory method, string memory name, string memory methodDescription, FieldDescriptor[] memory outputs)
        private
        pure
    {
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

    function _viewUintInput(
        VaultMethodSchema memory method,
        string memory name,
        string memory methodDescription,
        FieldDescriptor[] memory outputs,
        string memory inputName,
        string memory inputDescription
    ) private pure {
        method.name = name;
        method.description = methodDescription;
        method.inputs = new FieldDescriptor[](1);
        method.inputs[0] = FieldDescriptor(inputName, "uint256", inputDescription, 0);
        method.outputs = outputs;
        method.approvals = new ApproveAction[](0);
    }

    function _writeMintNFTByCount(VaultMethodSchema memory method) private pure {
        method.name = "mintNFTByCount";
        method.description = unicode"官网入口：按数量铸造 NFT。输入 1 = 铸造 1 张 NFT，每张 NFT 消耗 100,000 Token。官网会按 quantity × 100,000 Token 自动授权；Flap 用户建议使用 mint1NFT / mint2NFT / mint5NFT / mint10NFT 快捷入口。";
        method.inputs = new FieldDescriptor[](1);
        method.inputs[0] = FieldDescriptor("quantity", "uint256", unicode"铸造数量，例如 1、2、5、10。", 0);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](0);
        method.isWriteMethod = true;
    }

    function _writeEnterQueue(VaultMethodSchema memory method) private pure {
        method.name = "enterQueue";
        method.description = unicode"加入同档位多人 Round。用户质押当前档位对应 Token 和 1 张 NFT。第一位用户加入后开始 5 分钟倒计时，倒计时内同档位用户均可加入。一轮只产生 1 名唯一赢家；赢家获得所有输家 70% Token，所有输家 15% Token 销毁，15% Token 进入 LossVault，输家 NFT 被销毁。";
        method.inputs = new FieldDescriptor[](2);
        method.inputs[0] = FieldDescriptor("tierId", "uint256", unicode"档位编号。0=100,000，1=500,000，2=2,000,000，3=5,000,000，4=10,000,000 Token。", 0);
        method.inputs[1] = FieldDescriptor("nftId", "uint256", unicode"用于入场的 NFT ID。每轮需要锁定 1 张 NFT，Round 中暂停 NFT 分红。", 0);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](0);
        method.isWriteMethod = true;
    }

    function _writeTierInput(VaultMethodSchema memory method, string memory name, string memory methodDescription) private pure {
        method.name = name;
        method.description = methodDescription;
        method.inputs = new FieldDescriptor[](1);
        method.inputs[0] = FieldDescriptor("tierId", "uint256", unicode"档位编号。", 0);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](0);
        method.isWriteMethod = true;
    }

    function _writeRoundId(VaultMethodSchema memory method, string memory name, string memory methodDescription) private pure {
        method.name = name;
        method.description = methodDescription;
        method.inputs = new FieldDescriptor[](1);
        method.inputs[0] = FieldDescriptor("roundId", "uint256", unicode"Round ID。", 0);
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

    function _statsOutputs() private pure returns (FieldDescriptor[] memory outputs) {
        outputs = new FieldDescriptor[](27);
        outputs[0] = FieldDescriptor(unicode"Tax Token 合约", "address", unicode"Tax Token 合约地址。", 0);
        outputs[1] = FieldDescriptor(unicode"PVP NFT 合约", "address", unicode"PVP NFT 合约地址。", 0);
        outputs[2] = FieldDescriptor(unicode"历史累计铸造 NFT", "uint256", unicode"历史累计铸造 NFT 数量。", 0);
        outputs[3] = FieldDescriptor(unicode"当前存活 NFT", "uint256", unicode"当前仍存活的 NFT 数量，上限为 8,888。", 0);
        outputs[4] = FieldDescriptor(unicode"历史累计销毁 NFT", "uint256", unicode"输家累计被销毁的 NFT 数量。", 0);
        outputs[5] = FieldDescriptor(unicode"当前参与分红 NFT", "uint256", unicode"当前有效参与 NFT 分红的 NFT 数量。", 0);
        outputs[6] = FieldDescriptor(unicode"Round 中锁定 NFT", "uint256", unicode"当前锁定在 Round 中、暂停分红的 NFT 数量。", 0);
        outputs[7] = FieldDescriptor(unicode"NFT 分红 Token buffer", "uint256", unicode"等待兑换进入 NFT 分红池的 Token。", 18);
        outputs[8] = FieldDescriptor(unicode"LossVault 铸造 Token buffer", "uint256", unicode"铸造 NFT 产生、等待兑换进入 LossVault 的 Token。", 18);
        outputs[9] = FieldDescriptor(unicode"PVP LossVault Token buffer", "uint256", unicode"PVP 结算产生、等待进入 LossVault 的 Token。", 18);
        outputs[10] = FieldDescriptor(unicode"NFT 分红池 BNB", "uint256", unicode"已记账给 NFT 持有人的 BNB。", 18);
        outputs[11] = FieldDescriptor(unicode"LossVault 池 BNB", "uint256", unicode"已记账给 LossVault 的 BNB。", 18);
        outputs[12] = FieldDescriptor(unicode"NFT 未分配 BNB", "uint256", unicode"暂无有效 NFT 时暂存的 BNB。", 18);
        outputs[13] = FieldDescriptor(unicode"LossVault 未分配 BNB", "uint256", unicode"暂无 LossVault quota 时暂存的 BNB。", 18);
        outputs[14] = FieldDescriptor(unicode"当前有效 LossVault 总额度", "uint256", unicode"当前剩余可分配 LossVault quota。", 18);
        outputs[15] = FieldDescriptor(unicode"历史累计 LossVault quota", "uint256", unicode"历史累计发放的 LossVault quota。", 18);
        outputs[16] = FieldDescriptor(unicode"历史累计已领 LossVault BNB", "uint256", unicode"历史累计已领取 LossVault BNB。", 18);
        outputs[17] = FieldDescriptor(unicode"历史累计已领 NFT BNB", "uint256", unicode"历史累计已领取 NFT 分红 BNB。", 18);
        outputs[18] = FieldDescriptor(unicode"历史累计销毁 Token", "uint256", unicode"历史累计转入 DEAD 地址的 Token。", 18);
        outputs[19] = FieldDescriptor(unicode"总 Round 数量", "uint256", unicode"历史累计创建 Round 数量。", 0);
        outputs[20] = FieldDescriptor(unicode"已结算 Round", "uint256", unicode"历史累计已结算 Round 数量。", 0);
        outputs[21] = FieldDescriptor(unicode"当前开放 Round", "uint256", unicode"当前仍开放等待加入的 Round 数量。", 0);
        outputs[22] = FieldDescriptor(unicode"历史累计参与人数", "uint256", unicode"历史累计 Round 参与次数。", 0);
        outputs[23] = FieldDescriptor(unicode"历史累计赢家", "uint256", unicode"历史累计赢家数量。", 0);
        outputs[24] = FieldDescriptor(unicode"历史累计输家", "uint256", unicode"历史累计输家数量。", 0);
        outputs[25] = FieldDescriptor(unicode"各档位当前 Round ID", "uint256[5]", unicode"tier 0-4 当前开放 Round ID。", 0);
        outputs[26] = FieldDescriptor(unicode"各档位当前等待人数", "uint256[5]", unicode"tier 0-4 当前 Round 参与人数。", 0);
    }

    function _myInfoOutputs() private pure returns (FieldDescriptor[] memory outputs) {
        outputs = new FieldDescriptor[](19);
        outputs[0] = FieldDescriptor(unicode"我的 NFT 数量", "uint256", unicode"当前钱包持有的 NFT 数量。", 0);
        outputs[1] = FieldDescriptor(unicode"我的有效分红 NFT", "uint256", unicode"当前参与分红的 NFT 数量，Round 中 NFT 暂停分红。", 0);
        outputs[2] = FieldDescriptor(unicode"我的可领取 NFT 分红", "uint256", unicode"当前可领取 NFT BNB 分红。", 18);
        outputs[3] = FieldDescriptor(unicode"我的可领取 LossVault 分红", "uint256", unicode"当前可领取 LossVault BNB 分红。", 18);
        outputs[4] = FieldDescriptor(unicode"我的累计亏损本金估值", "uint256", unicode"按固定 BNB 估值累计的亏损本金。", 18);
        outputs[5] = FieldDescriptor(unicode"我的 LossVault 总额度", "uint256", unicode"历史累计获得的 LossVault quota。", 18);
        outputs[6] = FieldDescriptor(unicode"我的已领取 LossVault", "uint256", unicode"已领取的 LossVault BNB。", 18);
        outputs[7] = FieldDescriptor(unicode"我的剩余 LossVault 额度", "uint256", unicode"剩余可领取额度。", 18);
        outputs[8] = FieldDescriptor(unicode"我的参与总场次", "uint256", unicode"历史参与 Round 次数。", 0);
        outputs[9] = FieldDescriptor(unicode"我的胜场", "uint256", unicode"历史获胜次数。", 0);
        outputs[10] = FieldDescriptor(unicode"我的负场", "uint256", unicode"历史失败次数。", 0);
        outputs[11] = FieldDescriptor(unicode"当前 Round ID", "uint256", unicode"当前参与的 Round ID。", 0);
        outputs[12] = FieldDescriptor(unicode"当前 tier", "uint256", unicode"当前参与的档位。", 0);
        outputs[13] = FieldDescriptor(unicode"当前质押 NFT ID", "uint256", unicode"当前 Round 锁定的 NFT ID。", 0);
        outputs[14] = FieldDescriptor(unicode"当前质押 Token", "uint256", unicode"当前 Round 锁定的 Token 数量。", 18);
        outputs[15] = FieldDescriptor(unicode"当前 Round 状态", "uint8", unicode"0=None,1=Open,2=RandomnessRequested,3=RandomReady,4=Settled,5=Cancelled。", 0);
        outputs[16] = FieldDescriptor(unicode"当前 Round 参与人数", "uint256", unicode"当前 Round 参与人数。", 0);
        outputs[17] = FieldDescriptor(unicode"当前 Round 可开奖", "bool", unicode"是否可以请求 Chainlink VRF。", 0);
        outputs[18] = FieldDescriptor(unicode"当前 Round 可结算", "bool", unicode"是否可以结算。", 0);
    }

    function _roundOutputs() private pure returns (FieldDescriptor[] memory outputs) {
        outputs = new FieldDescriptor[](14);
        outputs[0] = FieldDescriptor(unicode"Round ID", "uint256", unicode"Round ID。", 0);
        outputs[1] = FieldDescriptor(unicode"档位", "uint256", unicode"Round 档位。", 0);
        outputs[2] = FieldDescriptor(unicode"质押 Token", "uint256", unicode"每位用户质押 Token 数量。", 18);
        outputs[3] = FieldDescriptor(unicode"开始时间", "uint256", unicode"Round 创建时间。", 0);
        outputs[4] = FieldDescriptor(unicode"加入截止时间", "uint256", unicode"5 分钟倒计时结束时间。", 0);
        outputs[5] = FieldDescriptor(unicode"VRF 请求时间", "uint256", unicode"请求 VRF 的时间。", 0);
        outputs[6] = FieldDescriptor(unicode"VRF requestId", "uint256", unicode"Chainlink VRF requestId。", 0);
        outputs[7] = FieldDescriptor(unicode"随机数", "uint256", unicode"VRF 返回的随机数。", 0);
        outputs[8] = FieldDescriptor(unicode"赢家", "address", unicode"本轮唯一赢家。", 0);
        outputs[9] = FieldDescriptor(unicode"状态", "uint8", unicode"0=None,1=Open,2=RandomnessRequested,3=RandomReady,4=Settled,5=Cancelled。", 0);
        outputs[10] = FieldDescriptor(unicode"参与人数", "uint256", unicode"当前参与人数。", 0);
        outputs[11] = FieldDescriptor(unicode"可请求 VRF", "bool", unicode"是否可以触发开奖。", 0);
        outputs[12] = FieldDescriptor(unicode"可结算", "bool", unicode"是否可以结算。", 0);
        outputs[13] = FieldDescriptor(unicode"可取消", "bool", unicode"是否可以超时取消。", 0);
    }

    function _boolOutput(string memory name, string memory description_) private pure returns (FieldDescriptor[] memory outputs) {
        outputs = new FieldDescriptor[](1);
        outputs[0] = FieldDescriptor(name, "bool", description_, 0);
    }
}
