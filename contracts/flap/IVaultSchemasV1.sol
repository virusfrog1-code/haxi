// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

struct FieldDescriptor {
    string name;
    string fieldType;
    string description;
    uint8 decimals;
}

struct VaultDataSchema {
    string description;
    FieldDescriptor[] fields;
    bool isArray;
}

struct ApproveAction {
    string tokenType;
    string amountFieldName;
}

struct VaultMethodSchema {
    string name;
    string description;
    FieldDescriptor[] inputs;
    FieldDescriptor[] outputs;
    ApproveAction[] approvals;
    bool isInputArray;
    bool isOutputArray;
    bool isWriteMethod;
}

struct VaultUISchema {
    string vaultType;
    string description;
    VaultMethodSchema[] methods;
}

struct FactoryPolicy {
    string target;
    string operator;
    bytes value;
    string description;
}
