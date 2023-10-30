# Let view the structure of our stablecoin project

1.  Relative Stability: Anchored or Pegged -> $1.00
    1.  Using Chainlink Price feed
    2.  Set a function to exchange ETH & BTC to dollar $ equivalent
2.  Stability Mechanism (Minting): Algorithmic (Decentralized)
    1.  People can only mint the stablecoin with enought collateral (coded)
3.  Collateral: Exogenous (backed by Crypto Collateral which are Ethereum and Bitcoin)
    We shall only allow the following cryptocurrency
    1.  ETH -> we shall be using Wrap ETH -> ERC20 version of Ether
    2.  BTC -> We shall be using Wrap BTC -> ERC20 version of Bitcoin

- calculate health factor function
- set health factor if debt is 0
- added a bunch of view function

1.  What are our invariant/properties of the system in that way we can write stateful and stateless fuzz test

- Fuzz testing: is when you supply random data to your system in an attempt to break it.
- Invariant: is property of our system that should always hold.
- Two methodology to find this edge cases:

1. Fuzz/Invariant Test
2. Symbolic Execution/Formal Verification

- Stateless Fuzzing: is where the state of the previous run is discarded for every new run.
- Statefull Fuzzing: is where the end state of our previous run is the starting state of the next run.
- Fuzz test will call all functions in a contract in a random order with random data.
- Foundry use invariant to describe the stateful fuzz
  Foundry fuzzing = Stateless fuzzing
  Foundry invariant = Stateful fuzzing
- Stateless Fuzz = Random data to one function
- Stateful Fuzz = Random data & Random function calls to many functions.

- open foundry.toml to add fuzzing test configuration like this
  [invariant]
  runs = 128
  depth = 128 #number of calls in a single run
  fail_on_revert = true
- let create fuzz folder inside test folder
  Handler.t.sol and InvariantsTest.t.sol

- Additional information

1.  Some proper oracle use
2.  Write more tests
3.  Smart Contract Audit Preparation
