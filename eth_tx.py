#!/usr/bin/env python3
"""
eth_tx.py — Ethereum Transaction Tool
Supports: ETH transfers, ERC-20 transfers, contract calls, contract deployment
Auth: Keystore file (UTC/JSON format)
Network: Mainnet (configurable via RPC_URL env var)
"""

import json
import os
import sys
import getpass
import argparse
from pathlib import Path

try:
    from web3 import Web3
    from eth_account import Account
except ImportError:
    print("Missing dependencies. Install with:")
    print("  pip install web3 eth-account")
    sys.exit(1)


# ── Config ────────────────────────────────────────────────────────────────────

DEFAULT_RPC = "https://mainnet.infura.io/v3/YOUR_INFURA_KEY"  # or any RPC URL

ERC20_ABI = [
    {
        "name": "transfer",
        "type": "function",
        "inputs": [
            {"name": "to", "type": "address"},
            {"name": "amount", "type": "uint256"},
        ],
        "outputs": [{"name": "", "type": "bool"}],
        "stateMutability": "nonpayable",
    },
    {
        "name": "decimals",
        "type": "function",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint8"}],
        "stateMutability": "view",
    },
    {
        "name": "symbol",
        "type": "function",
        "inputs": [],
        "outputs": [{"name": "", "type": "string"}],
        "stateMutability": "view",
    },
]


# ── Helpers ───────────────────────────────────────────────────────────────────

def connect(rpc_url: str) -> Web3:
    w3 = Web3(Web3.HTTPProvider(rpc_url))
    if not w3.is_connected():
        print(f"❌  Cannot connect to {rpc_url}")
        sys.exit(1)
    print(f"✅  Connected  chain_id={w3.eth.chain_id}  block={w3.eth.block_number}")
    return w3


def load_keystore(path: str) -> tuple[str, str]:
    """Load keystore file, prompt for password, return (address, private_key)."""
    ks_path = Path(path).expanduser()
    if not ks_path.exists():
        print(f"❌  Keystore not found: {ks_path}")
        sys.exit(1)

    with open(ks_path) as f:
        keystore = json.load(f)

    password = getpass.getpass("🔑  Keystore password: ")
    try:
        private_key = Account.decrypt(keystore, password)
    except Exception as e:
        print(f"❌  Failed to decrypt keystore: {e}")
        sys.exit(1)

    account = Account.from_key(private_key)
    print(f"👛  Wallet: {account.address}")
    return account.address, private_key.hex()


def build_base_tx(w3: Web3, sender: str, gas: int) -> dict:
    """Build common transaction fields."""
    return {
        "from": sender,
        "nonce": w3.eth.get_transaction_count(sender),
        "gasPrice": w3.eth.gas_price,
        "gas": gas,
        "chainId": w3.eth.chain_id,
    }


def sign_and_send(w3: Web3, tx: dict, private_key: str) -> str:
    """Sign, broadcast, and return the tx hash."""
    signed = Account.sign_transaction(tx, private_key)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    return tx_hash.hex()


def confirm(prompt: str) -> bool:
    return input(f"{prompt} [y/N] ").strip().lower() == "y"


# ── Transaction types ─────────────────────────────────────────────────────────

def send_eth(w3: Web3, sender: str, private_key: str, args):
    to = Web3.to_checksum_address(args.to)
    amount_wei = w3.to_wei(args.amount, "ether")

    print(f"\n📤  Send ETH")
    print(f"    To:     {to}")
    print(f"    Amount: {args.amount} ETH  ({amount_wei} wei)")

    if not confirm("Proceed?"):
        print("Aborted.")
        return

    tx = build_base_tx(w3, sender, gas=21000)
    tx.update({"to": to, "value": amount_wei})

    tx_hash = sign_and_send(w3, tx, private_key)
    print(f"✅  Sent!  tx={tx_hash}")
    print(f"    https://etherscan.io/tx/{tx_hash}")


def send_erc20(w3: Web3, sender: str, private_key: str, args):
    token_addr = Web3.to_checksum_address(args.token)
    to = Web3.to_checksum_address(args.to)
    contract = w3.eth.contract(address=token_addr, abi=ERC20_ABI)

    symbol = contract.functions.symbol().call()
    decimals = contract.functions.decimals().call()
    amount_units = int(float(args.amount) * 10**decimals)

    print(f"\n📤  Send ERC-20 ({symbol})")
    print(f"    Token:  {token_addr}")
    print(f"    To:     {to}")
    print(f"    Amount: {args.amount} {symbol}  ({amount_units} units)")

    if not confirm("Proceed?"):
        print("Aborted.")
        return

    tx = contract.functions.transfer(to, amount_units).build_transaction(
        build_base_tx(w3, sender, gas=args.gas)
    )

    tx_hash = sign_and_send(w3, tx, private_key)
    print(f"✅  Sent!  tx={tx_hash}")
    print(f"    https://etherscan.io/tx/{tx_hash}")


def call_contract(w3: Web3, sender: str, private_key: str, args):
    contract_addr = Web3.to_checksum_address(args.contract)

    with open(args.abi) as f:
        abi = json.load(f)

    contract = w3.eth.contract(address=contract_addr, abi=abi)

    # Parse function arguments
    fn_args = json.loads(args.args) if args.args else []
    value_wei = w3.to_wei(args.value, "ether") if args.value else 0

    print(f"\n📝  Call Contract")
    print(f"    Address:  {contract_addr}")
    print(f"    Function: {args.function}({', '.join(str(a) for a in fn_args)})")
    if value_wei:
        print(f"    Value:    {args.value} ETH")

    if not confirm("Proceed?"):
        print("Aborted.")
        return

    fn = getattr(contract.functions, args.function)
    tx = fn(*fn_args).build_transaction({
        **build_base_tx(w3, sender, gas=args.gas),
        "value": value_wei,
    })

    tx_hash = sign_and_send(w3, tx, private_key)
    print(f"✅  Called!  tx={tx_hash}")
    print(f"    https://etherscan.io/tx/{tx_hash}")


def deploy_contract(w3: Web3, sender: str, private_key: str, args):
    with open(args.abi) as f:
        abi = json.load(f)
    with open(args.bytecode) as f:
        bytecode = f.read().strip()

    constructor_args = json.loads(args.args) if args.args else []

    print(f"\n🚀  Deploy Contract")
    print(f"    ABI:      {args.abi}")
    print(f"    Bytecode: {args.bytecode}")
    if constructor_args:
        print(f"    Args:     {constructor_args}")

    if not confirm("Proceed?"):
        print("Aborted.")
        return

    contract = w3.eth.contract(abi=abi, bytecode=bytecode)
    tx = contract.constructor(*constructor_args).build_transaction(
        build_base_tx(w3, sender, gas=args.gas)
    )

    tx_hash = sign_and_send(w3, tx, private_key)
    print(f"✅  Deployed!  tx={tx_hash}")
    print(f"    https://etherscan.io/tx/{tx_hash}")
    print("    (check Etherscan for the contract address once mined)")


# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Ethereum transaction tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Send ETH
  python eth_tx.py --keystore ./UTC-... send-eth --to 0xABC... --amount 0.01

  # Send ERC-20
  python eth_tx.py --keystore ./UTC-... send-erc20 --token 0xTOKEN... --to 0xABC... --amount 100

  # Call a contract function
  python eth_tx.py --keystore ./UTC-... call --contract 0xCONTRACT... --abi abi.json --function mint --args '[1000]'

  # Deploy a contract
  python eth_tx.py --keystore ./UTC-... deploy --abi abi.json --bytecode bytecode.hex --args '["Hello"]'
        """,
    )

    parser.add_argument("--keystore", required=True, help="Path to UTC keystore JSON file")
    parser.add_argument(
        "--rpc",
        default=os.environ.get("ETH_RPC_URL", DEFAULT_RPC),
        help="Ethereum RPC URL (default: ETH_RPC_URL env or Infura mainnet)",
    )

    sub = parser.add_subparsers(dest="command", required=True)

    # send-eth
    p_eth = sub.add_parser("send-eth", help="Send ETH to an address")
    p_eth.add_argument("--to", required=True, help="Recipient address")
    p_eth.add_argument("--amount", required=True, type=float, help="Amount in ETH")

    # send-erc20
    p_erc20 = sub.add_parser("send-erc20", help="Send ERC-20 tokens")
    p_erc20.add_argument("--token", required=True, help="Token contract address")
    p_erc20.add_argument("--to", required=True, help="Recipient address")
    p_erc20.add_argument("--amount", required=True, type=float, help="Token amount (human-readable)")
    p_erc20.add_argument("--gas", type=int, default=100_000, help="Gas limit")

    # call
    p_call = sub.add_parser("call", help="Call a smart contract function")
    p_call.add_argument("--contract", required=True, help="Contract address")
    p_call.add_argument("--abi", required=True, help="Path to ABI JSON file")
    p_call.add_argument("--function", required=True, help="Function name")
    p_call.add_argument("--args", default=None, help="JSON array of arguments, e.g. '[1, \"hello\"]'")
    p_call.add_argument("--value", default=None, help="ETH value to send (optional)")
    p_call.add_argument("--gas", type=int, default=200_000, help="Gas limit")

    # deploy
    p_deploy = sub.add_parser("deploy", help="Deploy a smart contract")
    p_deploy.add_argument("--abi", required=True, help="Path to ABI JSON file")
    p_deploy.add_argument("--bytecode", required=True, help="Path to bytecode hex file")
    p_deploy.add_argument("--args", default=None, help="JSON array of constructor arguments")
    p_deploy.add_argument("--gas", type=int, default=3_000_000, help="Gas limit")

    args = parser.parse_args()

    # Connect & load wallet
    w3 = connect(args.rpc)
    sender, private_key = load_keystore(args.keystore)

    # Dispatch
    dispatch = {
        "send-eth": send_eth,
        "send-erc20": send_erc20,
        "call": call_contract,
        "deploy": deploy_contract,
    }
    dispatch[args.command](w3, sender, private_key, args)


if __name__ == "__main__":
    main()
