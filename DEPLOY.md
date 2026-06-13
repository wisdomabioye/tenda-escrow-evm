# TendaEscrow — EVM deploy runbook (BASE / CELO)

Status at time of writing: **contract code-complete, never deployed.** `forge build`
+ `forge test` are green (31/31), `forge` 1.7.1 is installed, `lib/` deps present.
No `broadcast/` artifacts exist — nothing is on-chain on any network. The server
adapter is written but dormant (all `BASE_*` / `CELO_*` env keys are unset, so
`chains/index.ts` registers Solana only).

This runbook covers BASE (eip155:8453). CELO (eip155:42220) is identical — swap the
`BASE_` prefixes for `CELO_` and the chain-specific addresses.

---

## 0. Prerequisites (the open #47 / #49 external work — do these FIRST)

These are gating and **not yet done**. The deploy cannot be trusted-for-production
until they are:

| Item | Produces | Needed for |
|---|---|---|
| **Safe 3-of-5 multisig on BASE** | `MULTISIG_BASE_ADDR` | `TENDA_ADMIN` + `TENDA_TREASURY` |
| **Dispute-authority key** (ops key at launch, can migrate to its own Safe) | `TENDA_DISPUTE_ADMIN` | constructor |
| **Alchemy account** (BASE app) | `BASE_RPC_URL`, `ALCHEMY_WEBHOOK_SECRET` | server adapter + event ingest |
| **Coinbase paymaster** (BASE) | `COINBASE_PAYMASTER_URL` | gasless UserOps (mobile #46) |
| **Solidity audit** | sign-off | mainnet only |
| **Deployer EOA** funded with ETH on BASE | `DEPLOYER_KEY` | broadcasting the deploy tx |
| **Basescan API key** | `--etherscan-api-key` | source verification |

> Do a full dress rehearsal on **Base Sepolia (eip155:84532)** before mainnet. Same
> steps, throwaway addresses, free testnet ETH from a faucet.

---

## 1. Pre-flight (in `tenda-escrow-evm/`)

```bash
cd /home/abioye/tenda/tenda-escrow-evm
forge build          # must compile (solc 0.8.35, via_ir)
forge test           # must be 31/31 green
forge fmt --check     # style gate
```

---

## 2. Resolve the constructor inputs

The deploy script (`script/Deploy.s.sol`) reads these from the environment:

**Required (no defaults — deploy reverts on `address(0)`):**

| Env var | Value |
|---|---|
| `TENDA_ADMIN` | the Safe 3-of-5 address (protocol admin **and** the natural treasury owner) |
| `TENDA_DISPUTE_ADMIN` | separate dispute authority (ops key at launch) |
| `TENDA_TREASURY` | fee recipient — normally the same Safe as `TENDA_ADMIN` |

**Optional (defaults mirror the Solana platform config — keep them unless product says otherwise):**

| Env var | Default | Meaning |
|---|---|---|
| `TENDA_FEE_BPS` | `250` | 2.50% platform fee |
| `TENDA_SEEKER_FEE_BPS` | `100` | 1.00% reduced seeker fee |
| `TENDA_APPROVAL_WINDOW_S` | `172800` | 48h poster review window |
| `TENDA_GRACE_PERIOD_S` | `3600` | 1h grace period |

> These four are validated on-chain (`_validateFeeBps`, `_validateApprovalWindow`,
> `_validateGracePeriod`). They are also mutable post-deploy via the admin (Safe)
> setters, so getting them exactly right at deploy time is not critical.

**Token addresses (for step 5, not the constructor — the contract is asset-agnostic):**

| Network | USDC (`BASE_USDC_ADDR`) |
|---|---|
| BASE mainnet (8453) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Base Sepolia (84532) | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |

> ⚠️ Verify both against Circle's official docs before use — a wrong token address
> silently routes funds to the wrong contract.

---

## 3. Deploy

```bash
export TENDA_ADMIN=0x...           # Safe 3-of-5
export TENDA_DISPUTE_ADMIN=0x...   # ops key
export TENDA_TREASURY=0x...        # = Safe, usually
export DEPLOYER_KEY=0x...          # funded EOA private key (NOT a Safe)
export BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/<key>
export BASESCAN_API_KEY=...

forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$BASE_RPC_URL" \
  --broadcast \
  --verify --etherscan-api-key "$BASESCAN_API_KEY" \
  --private-key "$DEPLOYER_KEY"
```

The script logs `TendaEscrow deployed: 0x...` — **that address is `BASE_ESCROW_ADDR`.**
Foundry also writes `broadcast/Deploy.s.sol/8453/run-latest.json` (commit-worthy
deployment record) and the verified source on Basescan.

> The deployer EOA only constructs the contract; it holds **no** privileged role
> afterward. All authority sits with `TENDA_ADMIN` (the Safe) and
> `TENDA_DISPUTE_ADMIN`. There is nothing to renounce.

---

## 4. Post-deploy sanity checks (read-only)

```bash
cast call $BASE_ESCROW_ADDR "admin()(address)"        --rpc-url $BASE_RPC_URL  # == Safe
cast call $BASE_ESCROW_ADDR "disputeAdmin()(address)" --rpc-url $BASE_RPC_URL
cast call $BASE_ESCROW_ADDR "treasury()(address)"     --rpc-url $BASE_RPC_URL
cast call $BASE_ESCROW_ADDR "feeBps()(uint16)"        --rpc-url $BASE_RPC_URL  # 250
```

---

## 5. Wire the server (`apps/server/.env`)

Add — **all of these, or the chain stays unregistered.** The adapter gate is
`config.BASE_RPC_URL !== null && config.BASE_ESCROW_ADDR !== null`
(`apps/server/src/chains/index.ts:79`); the seed needs the escrow **and** multisig
addresses together (`seed-v2.ts:112` warns on half-config):

```dotenv
BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/<key>
BASE_ESCROW_ADDR=0x...            # from step 3 deploy output
BASE_USDC_ADDR=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
MULTISIG_BASE_ADDR=0x...          # the Safe (treasury_address in the chain row)
COINBASE_PAYMASTER_URL=https://...
ALCHEMY_WEBHOOK_SECRET=...        # HMAC signing key from the Alchemy webhook
```

Then seed the chain + asset registry rows (USDC_BASE + ETH_BASE):

```bash
cd apps/server
pnpm db:seed-v2        # idempotent; inserts eip155:8453 chain row + assets
```

Restart the server. On boot the registry now mounts the BASE adapter; without the
keys it silently registers Solana only (no crash).

---

## 6. Event ingestion — Alchemy webhook

Create an Alchemy **Custom Webhook** (or Address Activity) on the BASE app pointed at:

```
POST https://<server-host>/v1/webhooks/alchemy
```

- Watch address: `BASE_ESCROW_ADDR`.
- The signing key Alchemy generates is `ALCHEMY_WEBHOOK_SECRET`; the route verifies
  the HMAC (`src/core/webhooks/verify-hmac.ts`) and drops unsigned/mismatched calls.
- This is the push path that confirms on-chain escrow events; the client-ping
  (`POST /v1/blockchain/transaction`) + BullMQ verify-tx job is the pull fallback.

---

## 7. End-to-end smoke (testnet first)

1. Mobile: pick BASE as the chain in gig-create, fund a test wallet with Sepolia
   USDC + ETH.
2. Create → accept → submit → approve → claim a full escrow lifecycle.
3. Confirm each transition emits the expected event (`EscrowCreated`,
   `EscrowAccepted`, `ProofSubmitted`, `EscrowApproved`, `PaymentClaimed`) and that
   the server's verify-tx job + WS republish reflect it.
4. Confirm fee math: `treasury` receives `feeBps`/`seekerFeeBps` of principal.

---

## 8. CELO (eip155:42220) — deltas only

Same flow, with: `CELO_RPC_URL`, `CELO_ESCROW_ADDR`, `MULTISIG_CELO_ADDR`. CELO uses
`feeCurrency=cUSD` on every tx (no paymaster, no UserOp counter — token addresses are
canonical mainnet constants in `apps/server/src/chains/celo/config.ts`). Confirmation
margin is shorter. No `COINBASE_PAYMASTER_URL` / Alchemy paymaster needed.

---

## Rollback / kill-switch

There is no contract-level pause. To take EVM offline operationally, unset
`BASE_RPC_URL` / `BASE_ESCROW_ADDR` and restart the server — the adapter stops
registering and `eip155:8453` requests fail closed with
`no adapter registered for chain_id 'eip155:8453'`. Funds already in escrows remain
claimable directly on-chain via the Safe.
