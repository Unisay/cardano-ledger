{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Main where

import qualified Bench.Control.Iterate.SetAlgebra.Bimap as Bimap
import BenchUTxOAggregate (expr, genTestCase)
import BenchValidation
  ( applyBlock,
    benchValidate,
    benchreValidate,
    genUpdateInputs,
    updateAndTickChain,
    updateChain,
    validateInput,
  )
import Cardano.Crypto.DSIGN
import Cardano.Crypto.Hash
import Cardano.Crypto.KES
import Cardano.Crypto.VRF.Praos
import Cardano.Ledger.Coin (Coin (..))
import qualified Cardano.Ledger.Crypto as CryptoClass
import Cardano.Ledger.Era (Crypto)
import Cardano.Ledger.Shelley (ShelleyEra)
import Cardano.Slotting.Slot (EpochSize (..))
import Control.DeepSeq (NFData)
import Control.Iterate.SetAlgebra (compile, compute, run)
import Control.SetAlgebra (dom, keysEqual, (▷), (◁))
import Criterion.Main
  ( Benchmark,
    bench,
    bgroup,
    defaultMain,
    env,
    nf,
    nfIO,
    whnf,
    whnfIO,
  )
import Data.Map (Map)
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy (..))
import Data.Word (Word64)
import Shelley.Spec.Ledger.API (PraosCrypto)
import Shelley.Spec.Ledger.Bench.Gen
  ( genBlock,
    genTriple,
  )
import Shelley.Spec.Ledger.Bench.Rewards (createRUpd, createRUpdWithProv, genChainInEpoch)
import qualified Shelley.Spec.Ledger.EpochBoundary as EB
import Shelley.Spec.Ledger.LedgerState
  ( DPState (..),
    DState (..),
    PState (..),
    UTxOState (..),
    stakeDistr,
  )
import Shelley.Spec.Ledger.PParams (PParams' (..))
import Shelley.Spec.Ledger.Rewards (likelihood)
import Shelley.Spec.Ledger.UTxO (UTxO)
import Test.QuickCheck (arbitrary)
import Test.QuickCheck.Gen as QC
import Test.Shelley.Spec.Ledger.BenchmarkFunctions
  ( initUTxO,
    ledgerDeRegisterStakeKeys,
    ledgerDelegateManyKeysOnePool,
    ledgerReRegisterStakePools,
    ledgerRegisterStakeKeys,
    ledgerRegisterStakePools,
    ledgerRetireStakePools,
    ledgerRewardWithdrawals,
    ledgerSpendOneGivenUTxO,
    ledgerSpendOneUTxO,
    ledgerStateWithNkeysMpools,
    ledgerStateWithNregisteredKeys,
    ledgerStateWithNregisteredPools,
  )
import Test.Shelley.Spec.Ledger.Utils (ShelleyTest, testGlobals)

-- Generator for coin. This is required, but its ouput is completely discarded.
-- What is going on here?
--
-- In order to support running tests in multiple eras (which may have different
-- values) we allow providing a value generator from the top level. However,
-- this value generator is currently only used to generate the non-coin part of
-- the value, since we pass additional arguments to the coin generator.
--
-- However, in the Shelley era, the value _is_ Coin, so anything generated by
-- this is immediately overridden by the specialised `Coin` generator.
--
-- The correct solution here will be to allow passing a generator which can have
-- the correct arguments plumbed in. At that point we can remove the specialised
-- Coin generator with its overrides, and simply establish the correct generator
-- from the top for the correct era.
--
-- TODO CAD-2119 covers the task of fixing this generator infrastructure.
genVl :: Gen Coin
genVl = arbitrary

-- ==========================================================

data BenchCrypto

instance CryptoClass.Crypto BenchCrypto where
  type DSIGN BenchCrypto = Ed25519DSIGN
  type KES BenchCrypto = Sum6KES Ed25519DSIGN Blake2b_256
  type VRF BenchCrypto = PraosVRF
  type HASH BenchCrypto = Blake2b_256
  type ADDRHASH BenchCrypto = Blake2b_224

instance PraosCrypto BenchCrypto

type BenchEra = ShelleyEra BenchCrypto

-- ============================================================

--TODO set this in one place (where?)
type FixedValType = Coin

eqf :: String -> (Map.Map Int Int -> Map.Map Int Int -> Bool) -> Int -> Benchmark
eqf name f n = bgroup (name ++ " " ++ show n) (map runat [n, n * 10, n * 100, n * 1000])
  where
    runat m =
      env
        ( return $
            Map.fromList
              [ (k, k)
                | k <- [1 .. m]
              ]
        )
        (\state -> bench (show m) (whnf (f state) state))

mainEq :: IO ()
mainEq =
  defaultMain $
    [ bgroup "KeysEqual tests" $
        [ eqf "keysEqual" keysEqual (100 :: Int),
          eqf
            "keys x == keys y"
            (\x y -> Map.keys x == Map.keys y)
            (100 :: Int)
        ]
    ]

-- =================================================
-- Spending 1 UTxO

includes_init_SpendOneUTxO :: IO ()
includes_init_SpendOneUTxO =
  defaultMain
    [ bgroup "Spend 1 UTXO with initialization" $
        fmap
          (\n -> bench (show n) $ whnf ledgerSpendOneUTxO n)
          [50, 500, 5000, 50000]
    ]

profileUTxO :: IO ()
profileUTxO = do
  putStrLn "Enter profiling"
  let ans = ledgerSpendOneGivenUTxO (initUTxO 500000)
  putStrLn ("Exit profiling " ++ show ans)

-- ==========================================
-- Registering Stake Keys

touchDPState :: DPState crypto -> Int
touchDPState (DPState _x _y) = 1

touchUTxOState :: Shelley.Spec.Ledger.LedgerState.UTxOState cryto -> Int
touchUTxOState (UTxOState _utxo _deposited _fees _ppups) = 2

profileCreateRegKeys :: IO ()
profileCreateRegKeys = do
  putStrLn "Enter profiling stake key creation"
  let state = ledgerStateWithNregisteredKeys 1 500000 -- using 75,000 and 100,000 causes
  -- mainbench: internal error: PAP object entered!
  -- (GHC version 8.6.5 for x86_64_unknown_linux)
  -- Please report this as a GHC bug:  http://www.haskell.org/ghc/reportabug
  let touch (x, y) = touchUTxOState x + touchDPState y
  putStrLn ("Exit profiling " ++ show (touch state))

-- ============================================
-- Profiling N keys and M pools

profileNkeysMPools :: IO ()
profileNkeysMPools = do
  putStrLn "Enter N keys and M Pools"
  let unit =
        ledgerDelegateManyKeysOnePool
          50
          500
          (ledgerStateWithNkeysMpools 5000 500)
  putStrLn ("Exit profiling " ++ show unit)

-- ==========================================
-- Registering Pools

profileCreateRegPools :: Word64 -> IO ()
profileCreateRegPools size = do
  putStrLn "Enter profiling pool creation"
  let state = ledgerStateWithNregisteredPools 1 size
  let touch (x, y) = touchUTxOState x + touchDPState y
  putStrLn ("Exit profiling " ++ show (touch state))

-- ==========================================
-- Epoch Boundary

profileEpochBoundary :: IO ()
profileEpochBoundary =
  defaultMain $
    [ bgroup "aggregate stake" $
        epochAt <$> benchParameters
    ]
  where
    benchParameters :: [Int]
    benchParameters = [10000, 100000, 1000000]

epochAt :: Int -> Benchmark
epochAt x =
  env (QC.generate (genTestCase x (10000 :: Int))) $
    \arg ->
      bgroup
        ("UTxO=" ++ show x ++ ",  address=" ++ show (10000 :: Int))
        [ bench "Using maps" (whnf action2m arg)
        ]

action2m ::
  ShelleyTest era =>
  (DState (Crypto era), PState (Crypto era), UTxO era) ->
  EB.SnapShot (Crypto era)
action2m (dstate, pstate, utxo) = stakeDistr utxo dstate pstate

-- =================================================================

-- | Benchmarks for the various validation transitions exposed by the API
validGroup :: Benchmark
validGroup =
  bgroup "validation" $
    [ runAtUTxOSize 1000,
      runAtUTxOSize 100000,
      runAtUTxOSize 1000000
    ]
  where
    runAtUTxOSize n =
      bgroup (show n) $
        [ env (validateInput @BenchEra n) $ \arg ->
            bgroup
              "block"
              [ bench "applyBlockTransition" (nfIO $ benchValidate arg),
                bench "reapplyBlockTransition" (nf benchreValidate arg)
              ],
          env (genUpdateInputs @BenchEra n) $ \arg ->
            bgroup
              "protocol"
              [ bench "updateChainDepState" (nf updateChain arg),
                bench
                  "updateAndTickChainDepState"
                  (nf updateAndTickChain arg)
              ]
        ]

profileValid :: IO ()
profileValid = do
  state <- validateInput @BenchEra 10000
  let ans = sum [applyBlock @BenchEra state n | n <- [1 .. 10000 :: Int]]
  putStrLn (show ans)
  pure ()

-- ========================================================
-- Profile algorithms for  ((dom d ◁ r) ▷ dom rg)

domainRangeRestrict :: IO ()
domainRangeRestrict =
  defaultMain $
    [ bgroup "domain-range restict" $
        drrAt <$> benchParameters
    ]
  where
    benchParameters :: [Int]
    benchParameters = [1000, 10000, 100000]

drrAt :: Int -> Benchmark
drrAt x =
  env (expr x) $
    \arg ->
      bgroup
        ("size=" ++ show x)
        [ bench "compute" (whnf alg1 arg),
          bench "run . compile" (whnf alg2 arg)
        ]

alg1 :: (Map Int Int, Map Int Char, Map Char Char) -> Map Int Char
alg1 (d, r, rg) = compute ((dom d ◁ r) ▷ dom rg)

alg2 :: (Map Int Int, Map Int Char, Map Char Char) -> Map Int Char
alg2 (d, r, rg) = run $ compile ((dom d ◁ r) ▷ dom rg)

-- =================================================
-- Some things we might want to profile.

-- main :: IO()
-- main = profileUTxO
-- main = includes_init_SpendOneUTxO
-- main:: IO ()
-- main = profileCreateRegPools 10000
-- main = profileCreateRegPools 100000
-- main = profileNkeysMPools
-- main = profile_stakeDistr
-- main = profileEpochBoundary

-- =========================================================

varyState ::
  NFData state =>
  String ->
  Word64 ->
  [Word64] ->
  (Word64 -> Word64 -> state) ->
  (Word64 -> Word64 -> state -> ()) ->
  Benchmark
varyState tag fixed changes initstate action =
  bgroup ("state/" ++ tag ++ "/constant") $ map runAtSize changes
  where
    runAtSize n =
      env
        (return $ initstate 1 n)
        (\state -> bench (show n) (whnf (action fixed fixed) state))

varyInput ::
  NFData state =>
  String ->
  (Word64, Word64) ->
  [(Word64, Word64)] ->
  (Word64 -> Word64 -> state) ->
  (Word64 -> Word64 -> state -> ()) ->
  Benchmark
varyInput tag fixed changes initstate action =
  bgroup ("input/" ++ tag ++ "/growing") $ map runAtSize changes
  where
    runAtSize n =
      env
        (return $ initstate (fst fixed) (snd fixed))
        (\state -> bench (show n) (whnf (action (fst n) (snd n)) state))

varyDelegState ::
  NFData state =>
  String ->
  Word64 ->
  [Word64] ->
  (Word64 -> Word64 -> state) ->
  (Word64 -> Word64 -> state -> ()) ->
  Benchmark
varyDelegState tag fixed changes initstate action =
  bgroup ("state/" ++ tag ++ "/growing") $ map runAtSize changes
  where
    runAtSize n =
      env
        (return $ initstate n n)
        (\state -> bench (show n) (whnf (action 1 fixed) state))

-- =============================================================================

main :: IO ()
-- main=profileValid
main = do
  (genenv, chainstate, genTxfun) <- genTriple (Proxy :: Proxy BenchEra) 1000
  defaultMain $
    [ bgroup "vary input size" $
        [ varyInput
            "deregister key"
            (1, 5000)
            [(1, 50), (1, 500), (1, 5000)]
            ledgerStateWithNregisteredKeys
            ledgerDeRegisterStakeKeys,
          varyInput
            "register key"
            (20001, 25001)
            [(1, 50), (1, 500), (1, 5000)]
            ledgerStateWithNregisteredKeys
            ledgerRegisterStakeKeys,
          varyInput
            "withdrawal"
            (1, 5000)
            [(1, 50), (1, 500), (1, 5000)]
            ledgerStateWithNregisteredKeys
            ledgerRewardWithdrawals,
          varyInput
            "register pool"
            (1, 5000)
            [(1, 50), (1, 500), (1, 5000)]
            ledgerStateWithNregisteredPools
            ledgerRegisterStakePools,
          varyInput
            "reregister pool"
            (1, 5000)
            [(1, 50), (1, 500), (1, 5000)]
            ledgerStateWithNregisteredPools
            ledgerReRegisterStakePools,
          varyInput
            "retire pool"
            (1, 5000)
            [(1, 50), (1, 500), (1, 5000)]
            ledgerStateWithNregisteredPools
            ledgerRetireStakePools,
          varyInput
            "manyKeysOnePool"
            (5000, 5000)
            [(1, 50), (1, 500), (1, 5000)]
            ledgerStateWithNkeysMpools
            ledgerDelegateManyKeysOnePool
        ],
      bgroup "vary initial state" $
        [ varyState
            "spendOne"
            1
            [50, 500, 5000]
            (\_m n -> initUTxO (fromIntegral n))
            (\_m _ -> ledgerSpendOneGivenUTxO),
          varyState
            "register key"
            5001
            [50, 500, 5000]
            ledgerStateWithNregisteredKeys
            ledgerRegisterStakeKeys,
          varyState
            "deregister key"
            50
            [50, 500, 5000]
            ledgerStateWithNregisteredKeys
            ledgerDeRegisterStakeKeys,
          varyState
            "withdrawal"
            50
            [50, 500, 5000]
            ledgerStateWithNregisteredKeys
            ledgerRewardWithdrawals,
          varyState
            "register pool"
            5001
            [50, 500, 5000]
            ledgerStateWithNregisteredPools
            ledgerRegisterStakePools,
          varyState
            "reregister pool"
            5001
            [50, 500, 5000]
            ledgerStateWithNregisteredPools
            ledgerReRegisterStakePools,
          varyState
            "retire pool"
            50
            [50, 500, 5000]
            ledgerStateWithNregisteredPools
            ledgerRetireStakePools,
          varyDelegState
            "manyKeysOnePool"
            50
            [50, 500, 5000]
            ledgerStateWithNkeysMpools
            ledgerDelegateManyKeysOnePool
        ],
      bgroup "vary utxo at epoch boundary" $
        (epochAt <$> [5000, 50000, 500000]),
      bgroup "domain-range restict" $ drrAt <$> [10000, 100000, 1000000],
      validGroup,
      -- Benchmarks for the various generators
      bgroup "gen" $
        [ env
            (return chainstate)
            ( \cs ->
                bgroup
                  "block"
                  [ bench "genBlock" $ whnfIO $ genBlock genenv cs
                  ]
            ),
          bgroup
            "genTx"
            [ bench "1000" $ whnfIO $ genTxfun genenv
            ]
        ],
      bgroup "rewards" $
        [ env
            (generate $ genChainInEpoch 5)
            ( \cs ->
                bench "createRUpd" $ whnf (createRUpd testGlobals) cs
            ),
          env
            (generate $ genChainInEpoch 5)
            ( \cs ->
                bench "createRUpdWithProvenance" $ whnf (createRUpdWithProv testGlobals) cs
            ),
          bench "likelihood" $ whnf (likelihood 1234 0.1) (EpochSize 10000)
        ],
      bgroup "bimap" $ [Bimap.fromList]
    ]
