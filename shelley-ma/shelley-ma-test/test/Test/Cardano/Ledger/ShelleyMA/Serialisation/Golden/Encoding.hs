{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Golden tests that check CBOR token encoding.
module Test.Cardano.Ledger.ShelleyMA.Serialisation.Golden.Encoding (goldenEncodingTests) where

import qualified Cardano.Ledger.Core as Core
import Cardano.Ledger.Era (Crypto (..))
import Cardano.Ledger.Mary.Value (AssetName (..), PolicyID (..), Value (..))
import Cardano.Ledger.ShelleyMA.Metadata (Metadata, pattern Metadata)
import Cardano.Ledger.ShelleyMA.Timelocks (Timelock (..), ValidityInterval (..))
import Cardano.Ledger.ShelleyMA.TxBody (TxBody (..))
import qualified Cardano.Ledger.Val as Val
import Codec.CBOR.Encoding (Tokens (..))
import qualified Data.ByteString.Char8 as BS
import qualified Data.Map.Strict as Map
import qualified Data.Sequence.Strict as StrictSeq
import qualified Data.Set as Set
import Shelley.Spec.Ledger.Address (Addr (..))
import Shelley.Spec.Ledger.BaseTypes (Network (..), StrictMaybe (..))
import Shelley.Spec.Ledger.Coin (Coin (..))
import Shelley.Spec.Ledger.Credential (Credential (..), StakeReference (..))
import Shelley.Spec.Ledger.Keys (KeyHash (..), KeyRole (..), hashKey)
import qualified Shelley.Spec.Ledger.Metadata as SMD
import Shelley.Spec.Ledger.PParams
  ( PParams' (..),
    Update,
    pattern ProposedPPUpdates,
    pattern Update,
  )
import Shelley.Spec.Ledger.Slot (EpochNo (..), SlotNo (..))
import Shelley.Spec.Ledger.Tx (hashScript)
import Shelley.Spec.Ledger.TxBody
  ( DCert (..),
    DelegCert (..),
    RewardAcnt (..),
    TxIn (..),
    TxOut (..),
    Wdrl (..),
  )
import Test.Cardano.Ledger.EraBuffet (AllegraEra, MaryEra, TestCrypto)
import Test.Shelley.Spec.Ledger.Generator.EraGen (genesisId)
import Test.Shelley.Spec.Ledger.Serialisation.GoldenUtils
  ( ToTokens (..),
    checkEncodingCBOR,
    checkEncodingCBORAnnotated,
  )
import Test.Shelley.Spec.Ledger.Utils (mkGenKey, mkKeyPair)
import Test.Tasty (TestTree, testGroup)

type A = AllegraEra TestCrypto

type M = MaryEra TestCrypto

-- ===============================================
-- == Test Values for Building Timelock Scripts ==
-- ===============================================

policy1 :: forall era. Era era => Timelock era
policy1 = RequireAnyOf . StrictSeq.fromList $ []

policyID1 :: PolicyID M
policyID1 = PolicyID . hashScript $ policy1

policyID2 :: PolicyID M
policyID2 = PolicyID . hashScript . RequireAllOf . StrictSeq.fromList $ []

assetName1 :: BS.ByteString
assetName1 = BS.pack "a1"

assetName2 :: BS.ByteString
assetName2 = BS.pack "a2"

assetName3 :: BS.ByteString
assetName3 = BS.pack "a3"

-- ===========================================
-- == Test Values for Building Transactions ==
-- ===========================================

testGKeyHash :: KeyHash 'Genesis TestCrypto
testGKeyHash = hashKey . snd . mkGenKey $ (0, 0, 0, 0, 0)

testAddrE :: forall era. Crypto era ~ TestCrypto => Addr era
testAddrE =
  Addr
    Testnet
    (KeyHashObj . hashKey . snd $ mkKeyPair (0, 0, 0, 0, 1))
    StakeRefNull

testKeyHash :: KeyHash 'Staking TestCrypto
testKeyHash = hashKey . snd $ mkKeyPair (0, 0, 0, 0, 2)

testStakeCred :: forall era. Crypto era ~ TestCrypto => Credential 'Staking era
testStakeCred = KeyHashObj . hashKey . snd $ mkKeyPair (0, 0, 0, 0, 3)

testUpdate :: forall era. (Crypto era ~ TestCrypto) => Update era
testUpdate =
  Update
    ( ProposedPPUpdates
        ( Map.singleton
            testGKeyHash
            ( PParams
                { _minfeeA = SNothing,
                  _minfeeB = SNothing,
                  _maxBBSize = SNothing,
                  _maxTxSize = SNothing,
                  _maxBHSize = SNothing,
                  _keyDeposit = SNothing,
                  _poolDeposit = SNothing,
                  _eMax = SNothing,
                  _nOpt = SJust 100,
                  _a0 = SNothing,
                  _rho = SNothing,
                  _tau = SNothing,
                  _d = SNothing,
                  _extraEntropy = SNothing,
                  _protocolVersion = SNothing,
                  _minUTxOValue = SNothing,
                  _minPoolCost = SNothing
                }
            )
        )
    )
    (EpochNo 0)

-- =============================================
-- == Golden Tests Common to Allegra and Mary ==
-- =============================================

scriptGoldenTest :: forall era. (Era era) => TestTree
scriptGoldenTest =
  let kh0 = hashKey . snd . mkGenKey $ (0, 0, 0, 0, 0) :: KeyHash 'Witness (Crypto era)
      kh1 = hashKey . snd . mkGenKey $ (1, 1, 1, 1, 1) :: KeyHash 'Witness (Crypto era)
   in checkEncodingCBORAnnotated
        "timelock_script"
        ( RequireAllOf
            ( StrictSeq.fromList
                [ RequireMOf 1 $ StrictSeq.fromList [RequireSignature kh0, RequireSignature kh1],
                  RequireTimeStart (SlotNo 100),
                  RequireTimeExpire (SlotNo 101)
                ]
            ) ::
            Timelock era
        )
        ( T
            ( TkListLen 2
                . TkInteger 1 -- label for RequireAllOf
                . TkListLen 3 -- RequireMOf, RequireTimeStart, RequireTimeExpire
                . TkListLen 3 -- label, m, signatures
                . TkInteger 3 -- label for RequireMOf
                . TkInteger 1 -- m value
                . TkListLen 2 -- two possible signatures
                . TkListLen 2 -- credential wrapper
                . TkInteger 0 -- label for keyhash
            )
            <> S kh0 -- keyhash
            <> T
              ( TkListLen 2 -- credential wrapper
                  . TkInteger 0 -- label for keyhash
              )
            <> S kh1 -- keyhash
            <> T
              ( TkListLen 2 -- RequireTimeStart
                  . TkInteger 4 -- label for RequireTimeStart
                  . TkInteger 100 -- start slot
                  . TkListLen 2 -- RequireTimeExpire
                  . TkInteger 5 -- label for RequireTimeExpire
                  . TkInteger 101 -- expire slot
              )
        )

metadataNoScritpsGoldenTest :: forall era. (Era era, Core.Script era ~ Timelock era) => TestTree
metadataNoScritpsGoldenTest =
  checkEncodingCBORAnnotated
    "metadata_no_scripts"
    (Metadata (Map.singleton 17 (SMD.I 42)) StrictSeq.empty :: Metadata era)
    ( T
        ( TkListLen 2 -- structured metadata and auxiliary scripts
            . TkMapLen 1 -- metadata wrapper
            . TkInteger 17
            . TkInteger 42
            . TkListLen 0 -- empty scripts
        )
    )

metadataWithScritpsGoldenTest :: forall era. (Era era, Core.Script era ~ Timelock era) => TestTree
metadataWithScritpsGoldenTest =
  checkEncodingCBORAnnotated
    "metadata_with_scripts"
    ( Metadata
        (Map.singleton 17 (SMD.I 42))
        (StrictSeq.singleton policy1) ::
        Metadata era
    )
    ( T
        ( TkListLen 2 -- structured metadata and auxiliary scripts
            . TkMapLen 1 -- metadata wrapper
            . TkInteger 17
            . TkInteger 42
            . TkListLen 1 -- one script
        )
        <> S (policy1 @era)
    )

-- | Golden Tests for Allegra
goldenEncodingTestsAllegra :: TestTree
goldenEncodingTestsAllegra =
  testGroup
    "Allegra"
    [ checkEncodingCBOR
        "value"
        (Val.inject (Coin 1) :: Value A)
        (T (TkInteger 1)),
      scriptGoldenTest @A,
      metadataNoScritpsGoldenTest @A,
      metadataWithScritpsGoldenTest @A,
      -- "minimal_txn_body"
      let tin = TxIn genesisId 1
          tout = TxOut (testAddrE @A) (Coin 2)
       in checkEncodingCBORAnnotated
            "minimal_txbody"
            ( TxBody
                (Set.fromList [tin])
                (StrictSeq.singleton tout)
                StrictSeq.empty
                (Wdrl Map.empty)
                (Coin 9)
                (ValidityInterval SNothing SNothing)
                SNothing
                SNothing
                (Coin 0)
            )
            ( T (TkMapLen 3)
                <> T (TkWord 0) -- Tx Ins
                <> T (TkListLen 1)
                <> S tin
                <> T (TkWord 1) -- Tx Outs
                <> T (TkListLen 1)
                <> S tout
                <> T (TkWord 2) -- Tx Fee
                <> T (TkWord64 9)
            ),
      -- "full_txn_body"
      let tin = TxIn genesisId 1
          tout = TxOut (testAddrE @A) (Coin 2)
          reg = DCertDeleg (RegKey testStakeCred)
          ras = Map.singleton (RewardAcnt Testnet (KeyHashObj testKeyHash)) (Coin 123)
          up = testUpdate
          mdh = SMD.hashMetadata $ Metadata Map.empty StrictSeq.empty
       in checkEncodingCBORAnnotated
            "full_txn_body"
            ( TxBody
                (Set.fromList [tin])
                (StrictSeq.singleton tout)
                (StrictSeq.fromList [reg])
                (Wdrl ras)
                (Coin 9)
                (ValidityInterval (SJust $ SlotNo 500) (SJust $ SlotNo 600))
                (SJust up)
                (SJust mdh)
                (Coin 0)
            )
            ( T (TkMapLen 9)
                <> T (TkWord 0) -- Tx Ins
                <> T (TkListLen 1)
                <> S tin
                <> T (TkWord 1) -- Tx Outs
                <> T (TkListLen 1)
                <> S tout
                <> T (TkWord 2) -- Tx Fee
                <> S (Coin 9)
                <> T (TkWord 3) -- Tx TTL
                <> S (SlotNo 600)
                <> T (TkWord 4) -- Tx Certs
                <> T (TkListLen 1) -- Seq list begin
                <> S reg
                <> T (TkWord 5) -- Tx Reward Withdrawals
                <> S ras
                <> T (TkWord 6) -- Tx Update
                <> S up
                <> T (TkWord 7) -- Tx Metadata Hash
                <> S mdh
                <> T (TkWord 8) -- Tx Validity Start
                <> S (SlotNo 500)
            )
    ]

-- | Golden Tests for Mary
goldenEncodingTestsMary :: TestTree
goldenEncodingTestsMary =
  testGroup
    "Mary"
    [ checkEncodingCBOR
        "ada_only_value"
        (Val.inject (Coin 1) :: Value M)
        (T (TkInteger 1)),
      checkEncodingCBOR
        "not_just_ada_value"
        ( Value 2 $
            Map.fromList
              [ ( policyID1,
                  Map.fromList
                    [ (AssetName assetName1, 13),
                      (AssetName assetName2, 17)
                    ]
                ),
                ( policyID2,
                  Map.singleton (AssetName assetName3) 19
                )
              ]
        )
        ( T
            ( TkListLen 2
                . TkInteger 2
                . TkMapLen 2
            )
            <> S policyID1
            <> T
              ( TkMapLen 2
                  . TkBytes assetName1
                  . TkInteger 13
                  . TkBytes assetName2
                  . TkInteger 17
              )
            <> S policyID2
            <> T
              ( TkMapLen 1
                  . TkBytes assetName3
                  . TkInteger 19
              )
        ),
      checkEncodingCBOR
        "value_with_negative"
        (Value 0 $ Map.singleton policyID1 (Map.singleton (AssetName assetName1) (-19)))
        ( T
            ( TkListLen 2
                . TkInteger 0
                . TkMapLen 1
            )
            <> S policyID1
            <> T
              ( TkMapLen 1
                  . TkBytes assetName1
                  . TkInteger (-19)
              )
        ),
      scriptGoldenTest @M,
      metadataNoScritpsGoldenTest @M,
      metadataWithScritpsGoldenTest @M,
      -- "minimal_txn_body"
      let tin = TxIn genesisId 1
          tout = TxOut (testAddrE @M) (Val.inject $ Coin 2)
       in checkEncodingCBORAnnotated
            "minimal_txbody"
            ( TxBody
                (Set.fromList [tin])
                (StrictSeq.singleton tout)
                StrictSeq.empty
                (Wdrl Map.empty)
                (Coin 9)
                (ValidityInterval SNothing SNothing)
                SNothing
                SNothing
                (Val.inject (Coin 0) :: Value M)
            )
            ( T (TkMapLen 3)
                <> T (TkWord 0) -- Tx Ins
                <> T (TkListLen 1)
                <> S tin
                <> T (TkWord 1) -- Tx Outs
                <> T (TkListLen 1)
                <> S tout
                <> T (TkWord 2) -- Tx Fee
                <> T (TkWord64 9)
            ),
      -- "full_txn_body"
      let tin = TxIn genesisId 1
          tout = TxOut (testAddrE @M) (Val.inject $ Coin 2)
          reg = DCertDeleg (RegKey testStakeCred)
          ras = Map.singleton (RewardAcnt Testnet (KeyHashObj testKeyHash)) (Coin 123)
          up = testUpdate
          mdh = SMD.hashMetadata $ Metadata Map.empty StrictSeq.empty
          mint = Map.singleton policyID1 $ Map.singleton (AssetName assetName1) 13
       in checkEncodingCBORAnnotated
            "full_txn_body"
            ( TxBody
                (Set.fromList [tin])
                (StrictSeq.singleton tout)
                (StrictSeq.fromList [reg])
                (Wdrl ras)
                (Coin 9)
                (ValidityInterval (SJust $ SlotNo 500) (SJust $ SlotNo 600))
                (SJust up)
                (SJust mdh)
                (Value 0 mint)
            )
            ( T (TkMapLen 10)
                <> T (TkWord 0) -- Tx Ins
                <> T (TkListLen 1)
                <> S tin
                <> T (TkWord 1) -- Tx Outs
                <> T (TkListLen 1)
                <> S tout
                <> T (TkWord 2) -- Tx Fee
                <> S (Coin 9)
                <> T (TkWord 3) -- Tx TTL
                <> S (SlotNo 600)
                <> T (TkWord 4) -- Tx Certs
                <> T (TkListLen 1)
                <> S reg
                <> T (TkWord 5) -- Tx Reward Withdrawals
                <> S ras
                <> T (TkWord 6) -- Tx Update
                <> S up
                <> T (TkWord 7) -- Tx Metadata Hash
                <> S mdh
                <> T (TkWord 8) -- Tx Validity Start
                <> S (SlotNo 500)
                <> T (TkWord 9) -- Tx Mint
                <> S mint
            )
    ]

-- | Golden Tests for Allegra and Mary
goldenEncodingTests :: TestTree
goldenEncodingTests =
  testGroup
    "Golden Encoding Tests"
    [ goldenEncodingTestsAllegra,
      goldenEncodingTestsMary
    ]
