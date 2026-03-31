#!/usr/bin/env python3
"""
deploy_chainminer.py
Compiles and deploys ORE → ChainMiner → MinerBadge, then wires them together.

Requirements:
  pip install web3 py-solc-x

Usage:
  python deploy_chainminer.py --keystore ./UTC-keystore.json

After deployment, paste the printed addresses into index.html.
"""

import json
import getpass
import argparse
import os
import sys
from pathlib import Path

try:
    from web3 import Web3
    from eth_account import Account
except ImportError:
    print("pip install web3")
    sys.exit(1)

try:
    from solcx import compile_files, install_solc, get_installed_solc_versions
except ImportError:
    print("pip install py-solc-x")
    sys.exit(1)

SOLC_VERSION = "0.8.20"
RPC_URL = os.environ.get("ETH_RPC_URL", "https://mainnet.infura.io/v3/YOUR_KEY")


def ensure_solc():
    installed = get_installed_solc_versions()
    if not any(str(v) == SOLC_VERSION for v in installed):
        print(f"Installing solc {SOLC_VERSION}...")
        install_solc(SOLC_VERSION)


def compile_contracts():
    print("Compiling contracts...")
    result = compile_files(
        ["ORE.sol", "ChainMiner.sol", "MinerBadge.sol"],
        output_values=["abi", "bin"],
        solc_version=SOLC_VERSION,
        optimize=True,
        optimize_runs=200,
    )
    ore_key    = next(k for k in result if k.endswith(":ORE"))
    miner_key  = next(k for k in result if k.endswith(":ChainMiner"))
    badge_key  = next(k for k in result if k.endswith(":MinerBadge"))
    return result[ore_key], result[miner_key], result[badge_key]


def load_keystore(path):
    ks_path = Path(path).expanduser()
    with open(ks_path) as f:
        keystore = json.load(f)
    password = getpass.getpass("🔑  Keystore password: ")
    private_key = Account.decrypt(keystore, password)
    acct = Account.from_key(private_key)
    print(f"👛  Deployer: {acct.address}")
    return acct.address, private_key.hex()


def deploy(w3, abi, bytecode, constructor_args, sender, private_key, label):
    print(f"\n🚀  Deploying {label}...")
    contract = w3.eth.contract(abi=abi, bytecode=bytecode)
    nonce = w3.eth.get_transaction_count(sender)
    tx = contract.constructor(*constructor_args).build_transaction({
        "from": sender,
        "nonce": nonce,
        "gasPrice": w3.eth.gas_price,
        "gas": 3_000_000,
        "chainId": w3.eth.chain_id,
    })
    signed = Account.sign_transaction(tx, private_key)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    print(f"    Tx: {tx_hash.hex()}")
    print(f"    Waiting for confirmation...")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=300)
    print(f"    ✅  {label} deployed at {receipt.contractAddress}")
    return receipt.contractAddress


def send_tx(w3, contract_fn, sender, private_key, label):
    print(f"\n🔗  {label}...")
    nonce = w3.eth.get_transaction_count(sender)
    tx = contract_fn.build_transaction({
        "from": sender,
        "nonce": nonce,
        "gasPrice": w3.eth.gas_price,
        "gas": 100_000,
        "chainId": w3.eth.chain_id,
    })
    signed = Account.sign_transaction(tx, private_key)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    w3.eth.wait_for_transaction_receipt(tx_hash)
    print(f"    ✅  Done!")


def save_artifacts(addresses, abis):
    for name, abi in abis.items():
        fname = f"{name.lower()}_abi.json"
        with open(fname, "w") as f:
            json.dump(abi, f, indent=2)
    print(f"\n📄  ABIs saved: ore_abi.json, chainminer_abi.json, minerbadge_abi.json")

    with open("deployment.json", "w") as f:
        json.dump(addresses, f, indent=2)
    print(f"📄  Addresses saved: deployment.json")


def main():
    parser = argparse.ArgumentParser(description="Deploy ChainMiner game contracts")
    parser.add_argument("--keystore", required=True)
    parser.add_argument("--rpc", default=RPC_URL)
    args = parser.parse_args()

    w3 = Web3(Web3.HTTPProvider(args.rpc))
    if not w3.is_connected():
        print("❌  Cannot connect to RPC"); sys.exit(1)
    print(f"✅  Connected  chain={w3.eth.chain_id}  block={w3.eth.block_number}")

    sender, private_key = load_keystore(args.keystore)

    ensure_solc()
    ore_art, miner_art, badge_art = compile_contracts()

    # Deploy in order: ORE → ChainMiner → MinerBadge
    ore_address   = deploy(w3, ore_art["abi"],   ore_art["bin"],   [],            sender, private_key, "ORE")
    miner_address = deploy(w3, miner_art["abi"], miner_art["bin"], [ore_address], sender, private_key, "ChainMiner")
    badge_address = deploy(w3, badge_art["abi"], badge_art["bin"], [miner_address], sender, private_key, "MinerBadge")

    # Wire up: set ChainMiner as the ORE minter
    ore_contract = w3.eth.contract(address=ore_address, abi=ore_art["abi"])
    send_tx(w3, ore_contract.functions.setMinter(miner_address), sender, private_key,
            "Setting ChainMiner as ORE minter")

    addresses = {
        "ORE":        ore_address,
        "ChainMiner": miner_address,
        "MinerBadge": badge_address,
    }

    save_artifacts(addresses, {
        "ore":        ore_art["abi"],
        "chainminer": miner_art["abi"],
        "minerbadge": badge_art["abi"],
    })

    print(f"""
╔══════════════════════════════════════════════════════════════╗
║                  DEPLOYMENT COMPLETE                         ║
╠══════════════════════════════════════════════════════════════╣
║  ORE Token:    {ore_address}
║  ChainMiner:   {miner_address}
║  MinerBadge:   {badge_address}
╠══════════════════════════════════════════════════════════════╣
║  Next steps:                                                 ║
║  1. Paste addresses into index.html (top of <script>)        ║
║  2. Open index.html in a browser with MetaMask               ║
║  3. Start mining!                                            ║
╚══════════════════════════════════════════════════════════════╝
    """)

    print(f"  ORE:        https://etherscan.io/address/{ore_address}")
    print(f"  ChainMiner: https://etherscan.io/address/{miner_address}")
    print(f"  MinerBadge: https://etherscan.io/address/{badge_address}")


if __name__ == "__main__":
    main()
