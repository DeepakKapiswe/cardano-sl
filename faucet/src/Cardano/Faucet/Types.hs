{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DuplicateRecordFields      #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeFamilies               #-}
{-# OPTIONS_GHC -Wall #-}
module Cardano.Faucet.Types (
    M, runM
  , MonadFaucet
  , module Cardano.Faucet.Types.Config
  , module Cardano.Faucet.Types.API
  ) where

import           Control.Lens
import           Control.Monad.Except
import           Control.Monad.Reader
import           Servant (ServantErr)
import           System.Wlog (CanLog, HasLoggerName, LoggerName (..),
                              LoggerNameBox (..), WithLogger, launchFromFile)

import           Cardano.Faucet.Types.API
import           Cardano.Faucet.Types.Config

--------------------------------------------------------------------------------
-- | Faucet monad
--
-- | Concrete monad stack for server server
newtype M a = M { unM :: ReaderT FaucetEnv (ExceptT ServantErr (LoggerNameBox IO)) a }
  deriving ( Functor, Applicative, Monad, MonadReader FaucetEnv, CanLog
           , HasLoggerName, MonadIO, MonadError ServantErr)

-- | Runs the 'M' monad
runM :: FaucetEnv -> M a -> IO (Either ServantErr a)
runM c = launchFromFile (c ^. feFaucetConfig . fcLoggerConfigFile) (LoggerName "faucet")
       . runExceptT
       . flip runReaderT c
       . unM

type MonadFaucet c m = ( MonadIO m, MonadReader c m, HasFaucetEnv c, WithLogger m
                       , HasLoggerName m, MonadError ServantErr m)
