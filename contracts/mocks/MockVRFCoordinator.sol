// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVrfConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

contract MockVRFCoordinator {
    uint256 public nextRequestId = 1;

    event RandomWordsRequested(uint256 indexed requestId);

    function requestRandomWords(bytes32, uint64, uint16, uint32, uint32) external returns (uint256 requestId) {
        requestId = nextRequestId++;
        emit RandomWordsRequested(requestId);
    }

    function fulfill(address consumer, uint256 requestId, uint256 randomness) external {
        uint256[] memory words = new uint256[](1);
        words[0] = randomness;
        IVrfConsumer(consumer).rawFulfillRandomWords(requestId, words);
    }
}
