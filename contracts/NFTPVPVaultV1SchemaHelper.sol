// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ApproveAction, FieldDescriptor, VaultMethodSchema, VaultUISchema} from "./flap/IVaultSchemasV1.sol";

contract NFTPVPVaultV1SchemaHelper {
    function vaultUISchema() external pure returns (VaultUISchema memory schema) {
        schema.vaultType = unicode"NFT PVP 多人 Round 分红金库";
        schema.description =
            unicode"NFT PVP 分红金库采用同档位多人 Round 机制。用户只需输入 Token 数量即可铸造 NFT 或加入 PVP。每 100,000 Token 铸造 1 张 NFT，输入 100000 = 铸造 1 张 NFT，输入 200000 = 铸造 2 张 NFT；加入 PVP 只需输入对赌 Token 数量，系统自动选择一张可用 NFT。第二位用户加入后开始 5 分钟倒计时，倒计时内同档位用户均可加入。倒计时结束后任何人可触发 Chainlink VRF 公平开奖，本轮只产生 1 名唯一赢家。赢家获得所有输家的 70% Token；所有输家的 15% Token 销毁，15% Token 进入 LossVault，输家 NFT 销毁，并获得最高亏损本金 150% 的 BNB 分红额度。LossVault 不是保证返还，实际领取取决于池子收入。";
        schema.methods = new VaultMethodSchema[](22);

        _writeTokenAmount(
            schema.methods[0],
            "mintNFT",
            unicode"铸造 NFT",
            unicode"输入用于铸造 NFT 的 Token 数量。每 100,000 Token 铸造 1 张 NFT。输入 100000 = 铸造 1 张，输入 200000 = 铸造 2 张。输入数量必须是 100,000 的整数倍。铸造资金中 50% 销毁，25% 进入 LossVault，25% 分红给 NFT 持有人。",
            unicode"铸造 Token 数量，例如 100000、200000、500000。"
        );
        _writeTokenAmount(
            schema.methods[1],
            "enterQueueByAmount",
            unicode"加入 PVP",
            unicode"加入 PVP 只需输入对赌 Token 数量。可输入 100000、500000、2000000、5000000、10000000。合约会自动识别档位并自动选择一张可用 NFT；NFT 进入 Round 后暂停分红。第二位用户加入后开始 5 分钟倒计时，一轮只有 1 名赢家，Chainlink VRF 公平开奖。",
            unicode"对赌 Token 数量，例如 100000、500000、2000000、5000000、10000000。"
        );
        _writeNoInput(schema.methods[2], "leaveQueue", unicode"退出当前 Round。用户无需填写档位编号；合约会自动找到当前参与的开放 Round，并退回 Token 和 NFT，NFT 恢复分红。");
        _writeNoInput(schema.methods[3], "claimNftDividends", unicode"领取 NFT 持有人 BNB 分红。Round 中的 NFT 暂停分红，退出或获胜后恢复分红；连续领取不会 underflow。");
        _writeNoInput(schema.methods[4], "claimLossDividends", unicode"领取 LossVault BNB 分红。PVP 输家最高获得亏损本金 150% 的额度，实际领取取决于 LossVault 池子收入。");

        _viewAddressInput(schema.methods[5], "getMyInfo", unicode"查看我的 Token 余额、NFT 数量、系统将自动使用的 NFT、当前 Round、胜负、NFT 分红和 LossVault 额度。", _myInfoOutputs());
        _viewNoInput(schema.methods[6], "getStats", unicode"查看金库总数据、NFT、Round、LossVault、销毁和分红数据。", _statsOutputs());
        _viewAddressInputSingle(schema.methods[7], "getAutoSelectedNFT", unicode"查看系统会自动选择哪张可用 NFT。返回 0 表示当前没有可用 NFT。", unicode"自动选择 NFT ID", 0);
        _viewAddressInput(schema.methods[8], "getMyLossInfo", unicode"查看指定用户的 LossVault 亏损本金、总额度、已领取、剩余额度和当前可领取 BNB。", _lossInfoOutputs());
        _viewUintInput(schema.methods[9], "getCurrentRound", unicode"查看指定档位当前 Round。档位：0=100,000，1=500,000，2=2,000,000，3=5,000,000，4=10,000,000 Token。", _roundOutputs(), "tierId", unicode"档位编号。");
        _viewUintInput(schema.methods[10], "getRound", unicode"查看 Round 状态、参与人数、倒计时、VRF、赢家，以及是否可开奖、结算或取消。", _roundOutputs(), "roundId", unicode"Round ID。");

        _writeRoundId(schema.methods[11], "requestRoundRandomness", unicode"请求 Chainlink VRF 开奖。Round 倒计时结束且至少 2 人参与后，任何人都可以调用；项目方不能指定赢家。");
        _writeRoundId(schema.methods[12], "settleRound", unicode"结算 Round。Chainlink VRF 随机数返回后，任何人都可以调用。若随机数未返回，会提示 RoundRandomNotReady。");
        _writeRoundId(schema.methods[13], "emergencyCancelRound", unicode"超时取消 Round。单人等待可取消；VRF 长时间未返回时参与者可取消。取消后 Token 和 NFT 退回，不产生输赢或 LossVault 额度。");

        _viewUintInput(schema.methods[14], "canRequestRoundRandomness", unicode"查看指定 Round 是否满足 Chainlink VRF 开奖条件。", _boolOutput(unicode"是否可请求 VRF", unicode"倒计时结束且至少 2 人参与，或达到最大人数时为 true。"), "roundId", unicode"Round ID。");
        _viewUintInput(schema.methods[15], "canSettleRound", unicode"查看指定 Round 是否已收到 VRF 随机数并可结算。", _boolOutput(unicode"是否可结算", unicode"VRF 随机数已返回时为 true。"), "roundId", unicode"Round ID。");
        _viewUintInput(schema.methods[16], "canEmergencyCancelRound", unicode"查看指定 Round 是否可以超时取消。", _boolOutput(unicode"是否可取消", unicode"单人等待或 VRF 超时未返回时为 true。"), "roundId", unicode"Round ID。");
        _viewUintInput(schema.methods[17], "getRoundStatus", unicode"查看指定 Round 当前状态。0=None,1=Open,2=RandomnessRequested,3=RandomReady,4=Settled,5=Cancelled。", _uintOutput(unicode"Round 状态", unicode"Round 当前状态。"), "roundId", unicode"Round ID。");
        _viewUintInput(schema.methods[18], "roundDeadline", unicode"查看指定 Round 的加入倒计时结束时间。第二位用户加入后才开始 5 分钟倒计时。", _uintOutput(unicode"倒计时结束时间", unicode"Round 的 5 分钟倒计时结束时间。"), "roundId", unicode"Round ID。");
        _viewUintInput(schema.methods[19], "roundRandomReady", unicode"查看指定 Round 是否已经收到 Chainlink VRF 随机数。", _boolOutput(unicode"随机数是否已返回", unicode"VRF 随机数已返回时为 true。"), "roundId", unicode"Round ID。");
        _viewAddressInputSingle(schema.methods[20], "pendingNftDividends", unicode"查看指定地址可领取的 NFT 持有人 BNB 分红。", unicode"可领取 NFT 分红", 18);
        _viewAddressInputSingle(schema.methods[21], "pendingLossDividends", unicode"查看指定地址可领取的 LossVault BNB 分红。", unicode"可领取 LossVault 分红", 18);
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

    function _writeTokenAmount(
        VaultMethodSchema memory method,
        string memory name,
        string memory title,
        string memory methodDescription,
        string memory inputDescription
    ) private pure {
        method.name = name;
        method.description = string.concat(title, unicode"：", methodDescription);
        method.inputs = new FieldDescriptor[](1);
        method.inputs[0] = FieldDescriptor("tokenAmount", "uint256", inputDescription, 18);
        method.outputs = new FieldDescriptor[](0);
        method.approvals = new ApproveAction[](1);
        method.approvals[0] = ApproveAction("taxToken", "tokenAmount");
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
        outputs = new FieldDescriptor[](29);
        outputs[0] = FieldDescriptor(unicode"Token 地址", "address", unicode"Tax Token 合约地址。", 0);
        outputs[1] = FieldDescriptor(unicode"NFT 地址", "address", unicode"PVP NFT 合约地址。", 0);
        outputs[2] = FieldDescriptor(unicode"NFT 总量上限", "uint256", unicode"NFT 总量上限 8,888。", 0);
        outputs[3] = FieldDescriptor(unicode"历史累计铸造 NFT", "uint256", unicode"历史累计铸造 NFT 数量。", 0);
        outputs[4] = FieldDescriptor(unicode"当前存活 NFT", "uint256", unicode"当前仍存活的 NFT 数量。", 0);
        outputs[5] = FieldDescriptor(unicode"历史累计销毁 NFT", "uint256", unicode"输家累计被销毁的 NFT 数量。", 0);
        outputs[6] = FieldDescriptor(unicode"当前有效分红 NFT", "uint256", unicode"当前参与 NFT 分红的 NFT 数量。", 0);
        outputs[7] = FieldDescriptor(unicode"Round 锁定 NFT", "uint256", unicode"当前锁定在 Round 中、暂停分红的 NFT 数量。", 0);
        outputs[8] = FieldDescriptor(unicode"NFT 分红 Token buffer", "uint256", unicode"等待兑换进入 NFT 分红池的 Token。", 18);
        outputs[9] = FieldDescriptor(unicode"LossVault 铸造 Token buffer", "uint256", unicode"铸造 NFT 产生、等待兑换进入 LossVault 的 Token。", 18);
        outputs[10] = FieldDescriptor(unicode"PVP LossVault Token buffer", "uint256", unicode"PVP 结算产生、等待进入 LossVault 的 Token。", 18);
        outputs[11] = FieldDescriptor(unicode"NFT 分红池 BNB", "uint256", unicode"已记账给 NFT 持有人的 BNB。", 18);
        outputs[12] = FieldDescriptor(unicode"LossVault BNB", "uint256", unicode"已记账给 LossVault 的 BNB。", 18);
        outputs[13] = FieldDescriptor(unicode"NFT 未分配 BNB", "uint256", unicode"暂无有效 NFT 时暂存的 BNB。", 18);
        outputs[14] = FieldDescriptor(unicode"LossVault 未分配 BNB", "uint256", unicode"暂无 LossVault quota 时暂存的 BNB。", 18);
        outputs[15] = FieldDescriptor(unicode"当前有效 LossVault 额度", "uint256", unicode"当前剩余可分配 LossVault quota。", 18);
        outputs[16] = FieldDescriptor(unicode"历史累计 LossVault quota", "uint256", unicode"历史累计发放的 LossVault quota。", 18);
        outputs[17] = FieldDescriptor(unicode"历史累计已领 LossVault BNB", "uint256", unicode"历史累计已领取 LossVault BNB。", 18);
        outputs[18] = FieldDescriptor(unicode"历史累计已领 NFT BNB", "uint256", unicode"历史累计已领取 NFT 分红 BNB。", 18);
        outputs[19] = FieldDescriptor(unicode"历史累计销毁 Token", "uint256", unicode"历史累计转入 DEAD 地址的 Token。", 18);
        outputs[20] = FieldDescriptor(unicode"总 Round 数量", "uint256", unicode"历史累计创建 Round 数量。", 0);
        outputs[21] = FieldDescriptor(unicode"已结算 Round", "uint256", unicode"历史累计已结算 Round 数量。", 0);
        outputs[22] = FieldDescriptor(unicode"当前开放 Round", "uint256", unicode"当前仍开放等待加入的 Round 数量。", 0);
        outputs[23] = FieldDescriptor(unicode"历史累计参与人数", "uint256", unicode"历史累计 Round 参与次数。", 0);
        outputs[24] = FieldDescriptor(unicode"历史累计赢家", "uint256", unicode"历史累计赢家数量。", 0);
        outputs[25] = FieldDescriptor(unicode"历史累计输家", "uint256", unicode"历史累计输家数量。", 0);
        outputs[26] = FieldDescriptor(unicode"各档当前 Round ID", "uint256[5]", unicode"tier 0-4 当前开放 Round ID。", 0);
        outputs[27] = FieldDescriptor(unicode"各档当前参与人数", "uint256[5]", unicode"tier 0-4 当前 Round 参与人数。", 0);
        outputs[28] = FieldDescriptor(unicode"各档倒计时结束时间", "uint256[5]", unicode"tier 0-4 当前 Round 的 5 分钟倒计时结束时间；0 表示等待第二位用户。", 0);
    }

    function _myInfoOutputs() private pure returns (FieldDescriptor[] memory outputs) {
        outputs = new FieldDescriptor[](22);
        outputs[0] = FieldDescriptor(unicode"我的 Token 余额", "uint256", unicode"当前钱包持有的 Token 数量。", 18);
        outputs[1] = FieldDescriptor(unicode"我的 NFT 数量", "uint256", unicode"当前钱包持有的 NFT 数量。", 0);
        outputs[2] = FieldDescriptor(unicode"自动选择 NFT ID", "uint256", unicode"加入 PVP 时系统将自动使用的第一张可用 NFT；0 表示没有可用 NFT。", 0);
        outputs[3] = FieldDescriptor(unicode"我的有效分红 NFT", "uint256", unicode"当前参与分红的 NFT 数量，Round 中 NFT 暂停分红。", 0);
        outputs[4] = FieldDescriptor(unicode"可领取 NFT 分红", "uint256", unicode"当前可领取的 NFT BNB 分红。", 18);
        outputs[5] = FieldDescriptor(unicode"可领取 LossVault", "uint256", unicode"当前可领取的 LossVault BNB 分红。", 18);
        outputs[6] = FieldDescriptor(unicode"累计亏损本金估值", "uint256", unicode"按固定 BNB 估值累计的亏损本金。", 18);
        outputs[7] = FieldDescriptor(unicode"LossVault 总额度", "uint256", unicode"历史累计获得的 LossVault quota。", 18);
        outputs[8] = FieldDescriptor(unicode"已领取 LossVault BNB", "uint256", unicode"已领取的 LossVault BNB。", 18);
        outputs[9] = FieldDescriptor(unicode"剩余 LossVault 额度", "uint256", unicode"剩余可领取额度。", 18);
        outputs[10] = FieldDescriptor(unicode"参与总场次", "uint256", unicode"历史参与 Round 次数。", 0);
        outputs[11] = FieldDescriptor(unicode"胜场", "uint256", unicode"历史获胜次数。", 0);
        outputs[12] = FieldDescriptor(unicode"负场", "uint256", unicode"历史失败次数。", 0);
        outputs[13] = FieldDescriptor(unicode"当前 Round ID", "uint256", unicode"当前参与的 Round ID。", 0);
        outputs[14] = FieldDescriptor(unicode"当前档位", "uint256", unicode"当前参与的档位。", 0);
        outputs[15] = FieldDescriptor(unicode"当前质押 NFT ID", "uint256", unicode"当前 Round 锁定的 NFT ID。", 0);
        outputs[16] = FieldDescriptor(unicode"当前质押 Token", "uint256", unicode"当前 Round 锁定的 Token 数量。", 18);
        outputs[17] = FieldDescriptor(unicode"当前 Round 状态", "uint8", unicode"0=None,1=Open,2=RandomnessRequested,3=RandomReady,4=Settled,5=Cancelled。", 0);
        outputs[18] = FieldDescriptor(unicode"当前 Round 参与人数", "uint256", unicode"当前 Round 参与人数。", 0);
        outputs[19] = FieldDescriptor(unicode"当前 Round 可开奖", "bool", unicode"是否可以请求 Chainlink VRF。", 0);
        outputs[20] = FieldDescriptor(unicode"当前 Round 可结算", "bool", unicode"是否可以结算。", 0);
        outputs[21] = FieldDescriptor(unicode"当前 Round 可取消", "bool", unicode"是否可以超时取消。", 0);
    }

    function _lossInfoOutputs() private pure returns (FieldDescriptor[] memory outputs) {
        outputs = new FieldDescriptor[](5);
        outputs[0] = FieldDescriptor(unicode"累计亏损本金估值", "uint256", unicode"按固定 BNB 估值累计的亏损本金。", 18);
        outputs[1] = FieldDescriptor(unicode"LossVault 总额度", "uint256", unicode"历史累计获得的 LossVault quota。", 18);
        outputs[2] = FieldDescriptor(unicode"已领取 BNB", "uint256", unicode"已领取的 LossVault BNB。", 18);
        outputs[3] = FieldDescriptor(unicode"剩余可领取额度", "uint256", unicode"剩余可领取的最高额度。", 18);
        outputs[4] = FieldDescriptor(unicode"当前可领取 BNB", "uint256", unicode"当前可领取的 LossVault BNB，受池子余额和额度上限限制。", 18);
    }

    function _roundOutputs() private pure returns (FieldDescriptor[] memory outputs) {
        outputs = new FieldDescriptor[](14);
        outputs[0] = FieldDescriptor(unicode"Round ID", "uint256", unicode"Round ID。", 0);
        outputs[1] = FieldDescriptor(unicode"档位", "uint256", unicode"Round 档位。", 0);
        outputs[2] = FieldDescriptor(unicode"质押 Token", "uint256", unicode"每位用户质押 Token 数量。", 18);
        outputs[3] = FieldDescriptor(unicode"开始时间", "uint256", unicode"第二位用户加入、倒计时开始的时间。", 0);
        outputs[4] = FieldDescriptor(unicode"倒计时结束时间", "uint256", unicode"5 分钟倒计时结束时间；0 表示等待第二位用户。", 0);
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

    function _uintOutput(string memory name, string memory description_) private pure returns (FieldDescriptor[] memory outputs) {
        outputs = new FieldDescriptor[](1);
        outputs[0] = FieldDescriptor(name, "uint256", description_, 0);
    }
}
