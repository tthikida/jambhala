{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
-- Required for `makeLift`:
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Contracts.Samples.Parameterized where

import Prelude hiding ( Applicative(..), Semigroup(..), Eq(..), Traversable(..), (<$>), mconcat )
import Jambhala.Plutus
import Jambhala.Haskell
import Jambhala.Utils

import Data.Aeson ( ToJSON, FromJSON )
import Data.Default ( Default(..) )
import Text.Printf ( printf )
import qualified Data.Map.Strict as Map

-- Datum
data VestingParam = VestingParam {
    getBeneficiary :: PaymentPubKeyHash
  , getDeadline    :: POSIXTime }
makeLift ''VestingParam

parameterized :: VestingParam -> () -> () -> ScriptContext -> Bool
parameterized (VestingParam ben dline) _ _ sc =
  traceIfFalse "Wrong pubkey hash" signedByBeneficiary &&
  traceIfFalse "Deadline not reached" dlineReached
  where
    txInfo              = scriptContextTxInfo sc
    signedByBeneficiary = txSignedBy txInfo $ unPaymentPubKeyHash ben
    dlineReached        = contains (from dline) $ txInfoValidRange txInfo
{-# INLINABLE parameterized #-}

validator :: VestingParam -> Validator
validator p = mkValidatorScript $ $$(compile [|| wrapped ||]) `applyCode` liftCode p
  where wrapped = mkUntypedValidator . parameterized

data VTypes
instance ValidatorTypes VTypes where
    type instance DatumType VTypes    = ()
    type instance RedeemerType VTypes = ()

data GiveParams = GiveParams
  { gpBeneficiary :: !PaymentPubKeyHash
  , gpDeadline    :: !POSIXTime
  , gpAmount      :: !Integer
  } deriving (Generic, ToJSON, FromJSON)

type Schema =
      Endpoint "give" GiveParams
  .\/ Endpoint "grab" POSIXTime

give :: GiveParams -> Contract () Schema Text ()
give (GiveParams{..}) = do
  submittedTxId <- getCardanoTxId <$> submitTxConstraintsWith @VTypes lookups constraints
  _ <- awaitTxConfirmed submittedTxId
  logInfo @String $ printf "Made a gift of %d lovelace to %s with deadline %s"
    gpAmount (show gpBeneficiary) (show gpDeadline)
  where
    vParam      = VestingParam { getBeneficiary = gpBeneficiary, getDeadline = gpDeadline }
    v           = validator vParam
    vHash       = validatorHash v
    lookups     = plutusV2OtherScript v
    constraints = mustPayToOtherScriptWithDatumInTx vHash unitDatum $ lovelaceValueOf gpAmount

grab :: POSIXTime -> Contract () Schema Text ()
grab dline = do
  pkh        <- ownFirstPaymentPubKeyHash
  now        <- uncurry interval <$> currentNodeClientTimeRange
  if from dline `contains` now then do
    let p = VestingParam { getBeneficiary = pkh, getDeadline = dline }
        v = validator p
    addr       <- getContractAddress v
    validUtxos <- utxosAt addr
    if Map.null validUtxos then logInfo @String $ "No eligible gifts available"
      else do
        let lookups     = unspentOutputs validUtxos <> plutusV2OtherScript v
            constraints = mconcat
                        $ mustValidateInTimeRange (fromPlutusInterval now)
                        : mustBeSignedBy pkh
                        : map (`mustSpendScriptOutput` unitRedeemer) (Map.keys validUtxos)
        submittedTx <- getCardanoTxId <$> submitTxConstraintsWith @VTypes lookups constraints
        _           <- awaitTxConfirmed submittedTx
        logInfo @String "Collected eligible gifts"
    else logInfo @String "Deadline not reached"

endpoints :: Contract () Schema Text ()
endpoints = awaitPromise (give' `select` grab') >> endpoints
  where
    give' = endpoint @"give" give
    grab' = endpoint @"grab" grab

test :: JambEmulatorTrace
test = do
  hs <- activateWallets endpoints
  let dline = slotToBeginPOSIXTime def 20
  sequence_
    [
      callEndpoint @"give" (hs ! 1) $ GiveParams {
        gpBeneficiary = mockWalletPaymentPubKeyHash $ knownWallet 2
      , gpDeadline    = dline
      , gpAmount      = 30_000_000
      }
    , wait1
    , callEndpoint @"give" (hs ! 1) $ GiveParams {
      gpBeneficiary = mockWalletPaymentPubKeyHash $ knownWallet 4
    , gpDeadline    = slotToBeginPOSIXTime def 20
    , gpAmount      = 30_000_000
    }
    , wait1
    , callEndpoint @"grab" (hs ! 2) dline -- deadline not reached
    , void $ waitUntilSlot 20
    , callEndpoint @"grab" (hs ! 3) dline -- wrong beneficiary
    , wait1
    , callEndpoint @"grab" (hs ! 4) dline -- collect gift
    ]

exports :: ContractExports -- Prepare exports for jamb CLI:
exports = exportValidatorWithTest (validator p) test 4
  where
    -- validator must be applied to some parameter to generate a hash or write script to file
    p = VestingParam
      { getBeneficiary = mockWalletPaymentPubKeyHash $ knownWallet 2
      , getDeadline    = slotToBeginPOSIXTime def 20 }