# LightLend Looping Contracts

---

To open position:

- use flashloan to get debtAsset
- swap debtAsset to yieldAsset
- supply yieldAsset
- borrow debtAsset to repay flashloan

To close position:

- use flashloan to get debtAsset
- repay debt
- withdraw yieldAsset
- swap yieldAsset to debtAsset
- repay flashloan

---

Users must approve:
- `Looping` contract to spend the initial amount of `debtAsset`
- `Looping` contract to spend `VariableDebtToken` of `debtAsset` (using `approveDelegation`, so contract can borrow on behalf of the user).

---

## PositionsManager

Positions Manager keeps track of different leveraged positions.

---

## StrategyManager & StrategyManagerFactory

`StrategyManager` is a **single-user strategy account**, not a shared protocol contract. Each instance is deployed per user via `StrategyManagerFactory.createStrategyManager(pool, yieldAsset, debtAsset)`:

- the factory sets the **caller** as the owner of the new instance (`Ownable2Step`),
- one instance exists per `(user, pool, yieldAsset, debtAsset)` combination (`getStrategyId` guards duplicates),
- the factory tracks all instances per user (`getUserStrategyManagers` / `getUserStrategyManager`), which the UI uses to find a user's strategy accounts.

### About the `executeCall` / `executeMultiCall` WARNING

The natspec warning in `StrategyManager.sol` ("allows arbitrary external calls") describes an **intentional design choice**, not a vulnerability:

- both functions are `onlyOwner`, and the owner is the individual user the factory deployed the instance for,
- the contract only ever holds that one user's funds — the owner is the sole beneficiary, so "arbitrary calls" can only put the owner's own funds at risk,
- this is what makes the account generic: leverage loops, migrations, and rescue operations can be composed without upgrading the contract.

The warning exists because the pattern **must not be copied** into any multi-user or shared-fund context. Never point shared funds, protocol treasuries, or third-party allowances at a `StrategyManager`.