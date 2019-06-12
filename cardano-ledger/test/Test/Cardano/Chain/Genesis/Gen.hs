module Test.Cardano.Chain.Genesis.Gen
  ( genCanonicalGenesisData
  , genCanonicalGenesisDelegation
  , genGenesisData
  , genGenesisHash
  , genFakeAvvmOptions
  , genGenesisAvvmBalances
  , genGenesisDelegation
  , genGenesisInitializer
  , genGenesisNonAvvmBalances
  , genGenesisSpec
  , genGenesisKeyHashes
  , genSignatureEpochIndex
  , genTestnetBalanceOptions
  , genStaticConfig
  )
where

import Cardano.Prelude

import Data.Coerce (coerce)
import qualified Data.Text as T
import Data.Time (UTCTime(..), Day(..), secondsToDiffTime)
import qualified Data.Map.Strict as M
import Formatting (build, sformat)

import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

import Cardano.Chain.Common (BlockCount(..))
import Cardano.Chain.Genesis
  ( FakeAvvmOptions(..)
  , GenesisAvvmBalances(..)
  , GenesisData(..)
  , GenesisDelegation(..)
  , GenesisHash(..)
  , GenesisInitializer(..)
  , GenesisNonAvvmBalances(..)
  , GenesisSpec(..)
  , GenesisKeyHashes(..)
  , StaticConfig(..)
  , TestnetBalanceOptions(..)
  , mkGenesisDelegation
  , mkGenesisSpec
  )
import Cardano.Chain.Slotting (EpochIndex)
import Cardano.Crypto (ProtocolMagicId, Signature(..))
import qualified Cardano.Crypto.Wallet as CC

import Test.Cardano.Chain.Common.Gen
  (genAddress, genBlockCount, genLovelace, genLovelacePortion, genKeyHash)
import Test.Cardano.Chain.Delegation.Gen
  (genCanonicalCertificateDistinctList, genCertificateDistinctList)
import Test.Cardano.Chain.Update.Gen
  (genCanonicalProtocolParameters, genProtocolParameters)
import Test.Cardano.Crypto.Gen
  ( genHashRaw
  , genProtocolMagic
  , genProtocolMagicId
  , genRedeemVerificationKey
  , genTextHash
  )

genCanonicalGenesisData :: ProtocolMagicId -> Gen GenesisData
genCanonicalGenesisData pm =
  GenesisData
    <$> genGenesisKeyHashes
    <*> genCanonicalGenesisDelegation pm
    <*> genUTCTime
    <*> genGenesisNonAvvmBalances
    <*> genCanonicalProtocolParameters
    <*> genBlockCount'
    <*> genProtocolMagicId
    <*> genGenesisAvvmBalances
 where
  genBlockCount' :: Gen BlockCount
  genBlockCount' = BlockCount <$> (Gen.word64 $ Range.linear 0 1000000000)

genCanonicalGenesisDelegation :: ProtocolMagicId -> Gen GenesisDelegation
genCanonicalGenesisDelegation pm = do
  certificates <- genCanonicalCertificateDistinctList pm
  case mkGenesisDelegation certificates of
    Left  err    -> panic $ sformat build err
    Right genDel -> pure genDel

genGenesisData :: ProtocolMagicId -> Gen GenesisData
genGenesisData pm =
  GenesisData
    <$> genGenesisKeyHashes
    <*> genGenesisDelegation pm
    <*> genUTCTime
    <*> genGenesisNonAvvmBalances
    <*> genProtocolParameters
    <*> genBlockCount
    <*> genProtocolMagicId
    <*> genGenesisAvvmBalances

genGenesisHash :: Gen GenesisHash
genGenesisHash = do
  th <- genTextHash
  pure (GenesisHash (coerce th))

genStaticConfig :: ProtocolMagicId -> Gen StaticConfig
genStaticConfig pm = Gen.choice
  [ GCSrc <$> Gen.string (Range.constant 10 25) Gen.alphaNum <*> genHashRaw
  , GCSpec <$> genGenesisSpec pm
  ]

genFakeAvvmOptions :: Gen FakeAvvmOptions
genFakeAvvmOptions =
  FakeAvvmOptions <$> Gen.word Range.constantBounded <*> genLovelace

genGenesisDelegation :: ProtocolMagicId -> Gen GenesisDelegation
genGenesisDelegation pm = do
  certificates <- genCertificateDistinctList pm
  case mkGenesisDelegation certificates of
    Left  err    -> panic $ sformat build err
    Right genDel -> pure genDel

genGenesisInitializer :: Gen GenesisInitializer
genGenesisInitializer =
  GenesisInitializer
    <$> genTestnetBalanceOptions
    <*> genFakeAvvmOptions
    <*> genLovelacePortion
    <*> Gen.bool
    <*> Gen.integral (Range.constant 0 10)

genGenesisNonAvvmBalances :: Gen GenesisNonAvvmBalances
genGenesisNonAvvmBalances = do
  hmSize    <- Gen.int $ Range.linear 1 10
  addresses <- Gen.list (Range.singleton hmSize) genAddress
  ll        <- Gen.list (Range.singleton hmSize) genLovelace
  pure $ GenesisNonAvvmBalances $ M.fromList $ zip addresses ll

genGenesisSpec :: ProtocolMagicId -> Gen GenesisSpec
genGenesisSpec pm = mkGenSpec >>= either (panic . toS) pure
 where
  mkGenSpec =
    mkGenesisSpec
      <$> genGenesisAvvmBalances
      <*> genGenesisDelegation pm
      <*> genProtocolParameters
      <*> genBlockCount
      <*> genProtocolMagic
      <*> genGenesisInitializer

genTestnetBalanceOptions :: Gen TestnetBalanceOptions
genTestnetBalanceOptions =
  TestnetBalanceOptions
    <$> Gen.word Range.constantBounded
    <*> Gen.word Range.constantBounded
    <*> genLovelace
    <*> genLovelacePortion
    <*> Gen.bool

genGenesisAvvmBalances :: Gen GenesisAvvmBalances
genGenesisAvvmBalances =
  GenesisAvvmBalances <$> customMapGen genRedeemVerificationKey genLovelace

genGenesisKeyHashes :: Gen GenesisKeyHashes
genGenesisKeyHashes =
  GenesisKeyHashes <$> Gen.set (Range.constant 10 25) genKeyHash

genSignatureEpochIndex :: Gen (Signature EpochIndex)
genSignatureEpochIndex = do
  hex <- Gen.utf8 (Range.constant 64 64) Gen.hexit
  case CC.xsignature hex of
    Left  err -> panic $ T.pack err
    Right sig -> pure $ Signature sig

genUTCTime :: Gen UTCTime
genUTCTime = do
  jday    <- Gen.integral (Range.linear 0 1000000)
  seconds <- Gen.integral (Range.linear 0 86401)
  pure $ UTCTime (ModifiedJulianDay jday) (secondsToDiffTime seconds)

--------------------------------------------------------------------------------
-- Helper Generators
--------------------------------------------------------------------------------

customMapGen :: Ord k => Gen k -> Gen v -> Gen (Map k v)
customMapGen keyGen valGen =
  M.fromList <$> (Gen.list (Range.linear 1 10) $ (,) <$> keyGen <*> valGen)
