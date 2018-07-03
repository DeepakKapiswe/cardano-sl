{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns        #-}
{-# OPTIONS_GHC -Wall #-}
module Cardano.WalletClient (
    withdraw
  ) where

import           Cardano.Wallet.API.V1.Types (Payment (..), V1 (..))
import qualified Cardano.Wallet.API.V1.Types as V1
import           Cardano.Wallet.Client (Resp, Transaction, WalletClient (..))
import           Control.Concurrent.MVar (MVar, putMVar, takeMVar)
import           Control.Exception (bracket)
import           Control.Lens
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Reader
import           Crypto.Hash (Blake2b_256, Digest)
import qualified Crypto.Hash as CryptoHash
import qualified Data.ByteArray as BA
import           Data.ByteString (ByteString)
import           Data.List.NonEmpty (NonEmpty (..))
import           Data.Text.Strict.Lens (utf8)
import           Pos.Core (Address (..), Coin (..), getCoin)
import           Pos.Crypto.Signing (PassPhrase)
import           System.Random

import           Cardano.Faucet.Types

-- | Computes the amount of ADA (units in lovelace) to send in 'withdraw'
randomAmount :: (MonadIO m) => PaymentDistribution -> m (V1 Coin)
randomAmount (PaymentDistribution (getCoin -> amt) (getCoin -> var))= do
    (f :: Float) <- liftIO $ randomRIO ((-1), 1)
    return $ V1 $ Coin $ round $ ((fromIntegral amt) + ((fromIntegral var) * f))

-- | Client function for the handler for the @/withdraw@ action
--
-- Simply sends a 'randomAmount' of ADA (units in lovelace )to the supplied
-- 'Address'
withdraw :: (MonadFaucet c m) => V1 Address -> Resp m Transaction
withdraw addr = do
    paymentSource <- view (feSourceWallet . to cfgToPaymentSource)
    spendingPassword <- view (feSourceWallet . srcSpendingPassword)
    coin <- randomAmount =<< view (feFaucetConfig . fcPaymentDistribution)
    client <- view feWalletClient
    lock <- view feWithdrawlLock
    let paymentDist = (V1.PaymentDistribution addr coin :| [])
        sp =  spendingPassword <&> view (re utf8 . to hashPwd . to V1)
        payment = Payment paymentSource paymentDist Nothing sp
    liftIO $ runWithDraw client lock payment

runWithDraw :: WalletClient IO -> MVar () -> Payment -> Resp IO Transaction
runWithDraw wc mVar pmt =
    bracket (takeMVar mVar) (putMVar mVar) $ const $ postTransaction wc pmt

-- | Hashes bytestring password to the form expected by the wallet API
hashPwd :: ByteString -> PassPhrase
hashPwd  bs =
    let blake = CryptoHash.hash bs :: Digest (Blake2b_256)
    in BA.convert blake
