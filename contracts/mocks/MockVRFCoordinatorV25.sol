// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVRFConsumerV25 {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

contract MockVRFCoordinatorV25 {
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    uint256 public nextRequestId = 1;
    mapping(uint256 => address) public consumers;

    event RandomWordsRequested(uint256 indexed requestId, address indexed consumer);

    function requestRandomWords(RandomWordsRequest calldata) external returns (uint256 requestId) {
        requestId = nextRequestId++;
        consumers[requestId] = msg.sender;
        emit RandomWordsRequested(requestId, msg.sender);
    }

    function fulfill(uint256 requestId, uint256 randomWord) external {
        address consumer = consumers[requestId];
        require(consumer != address(0), "bad request");
        uint256[] memory words = new uint256[](1);
        words[0] = randomWord;
        IVRFConsumerV25(consumer).rawFulfillRandomWords(requestId, words);
    }
}
