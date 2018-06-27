{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

module Cardano.Wallet.Kernel.PrefilterTx
       ( PrefilteredBlock(..)
       , AddrWithId
       , prefilterBlock
       , prefilterUtxo
       ) where

import           Universum

import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text.Buildable
import           Formatting (bprint, (%))
import           Serokell.Util (listJson, mapJson)

import           Data.SafeCopy (base, deriveSafeCopy)

import           Pos.Core (Address (..), TxId)
import           Pos.Core.Txp (TxIn (..), TxOut (..), TxOutAux (..))
import           Pos.Crypto (EncryptedSecretKey)
import           Pos.Txp.Toil.Types (Utxo)
import           Pos.Wallet.Web.Tracking.Decrypt (WalletDecrCredentials, eskToWalletDecrCredentials,
                                                  selectOwnAddresses)
import           Pos.Wallet.Web.State.Storage (WAddressMeta (..))

import           Cardano.Wallet.Kernel.Types(WalletId (..))
import           Cardano.Wallet.Kernel.DB.HdWallet
import           Cardano.Wallet.Kernel.DB.InDb (InDb (..), fromDb)
import           Cardano.Wallet.Kernel.DB.Resolved (ResolvedBlock, ResolvedInput, ResolvedTx,
                                                    rbSlot, rbTxs, rtxInputs, rtxOutputs)
import           Cardano.Wallet.Kernel.DB.BlockMeta

{-------------------------------------------------------------------------------
 Pre-filter Tx Inputs and Outputs to those that belong to the given Wallet.
+-------------------------------------------------------------------------------}

-- | Extended Utxo with each output paired with an HdAddressId, required for
--   discovering new Addresses during prefiltering
type UtxoWithAddrId = Map TxIn (TxOutAux,HdAddressId)

-- | Address extended with an HdAddressId, which embeds information that places
--   the Address in the context of the Wallet/Accounts/Addresses hierarchy.
type AddrWithId = (HdAddressId,Address)

-- | Prefiltered block
--
-- A prefiltered block is a block that contains only inputs and outputs from
-- the block that are relevant to the wallet.
data PrefilteredBlock = PrefilteredBlock {
      -- | Relevant inputs
      pfbInputs  :: Set TxIn

      -- | Relevant outputs
    , pfbOutputs :: Utxo

      -- | all output addresses present in the Utxo
    , pfbAddrs   :: [AddrWithId]

      -- | Prefiltered block metadata
    , pfbMeta    :: BlockMeta
    }

deriveSafeCopy 1 'base ''PrefilteredBlock

type WalletKey = (WalletId, WalletDecrCredentials)

-- | Produce Utxo along with all (extended) addresses and TxIds ocurring in the Utxo
toPrefilteredUtxo :: UtxoWithAddrId -> (Utxo,[AddrWithId],[TxId])
toPrefilteredUtxo utxoWithAddrs = (Map.fromList utxoL, addrs, concat txIds)
    where
        toUtxo (txIn,(txOutAux,_))         = (txIn,txOutAux)
        toAddr (_   ,(txOutAux,addressId)) = (addressId, txOutAddress . toaOut $ txOutAux)

        toTxId ((TxInUtxo txId _),_)       = [txId]
        toTxId ((TxInUnknown _ _),_)       = []

        toSummary :: (TxIn,(TxOutAux,HdAddressId))
                  -> ((TxIn,TxOutAux), AddrWithId, [TxId])
        toSummary item = (toUtxo item, toAddr item, toTxId item)

        utxoSummary = map toSummary $ Map.toList utxoWithAddrs
        (utxoL, addrs, txIds) = unzip3 utxoSummary

-- | Version of `toPrefilteredUtxo` that discards TxIds
toPrefilteredUtxo' :: UtxoWithAddrId -> (Utxo,[AddrWithId])
toPrefilteredUtxo' utxoWithAddrs = (utxo, addrs)
    where
        (utxo, addrs, _) = toPrefilteredUtxo utxoWithAddrs

-- | Prefilter the transactions of a resolved block for the given wallet.
--
--   Returns prefiltered blocks indexed by HdAccountId.
prefilterBlock :: WalletId
               -> EncryptedSecretKey
               -> ResolvedBlock
               -> Map HdAccountId PrefilteredBlock
prefilterBlock wid esk block
    = Map.fromList $ map mkPrefBlock (Set.toList accountIds)
  where
    mkPrefBlock accId'
        = (accId', PrefilteredBlock inps' outs' addrs' blockMeta')
        where
            byAccountId accId'' def dict = fromMaybe def $ Map.lookup accId'' dict

            inps'                   =                    byAccountId accId' Set.empty inpAll
            (outs', addrs', txIds') = toPrefilteredUtxo (byAccountId accId' Map.empty outAll)

            blockMeta' = mkBlockMeta txIds'

    mkBlockMeta = BlockMeta . InDb . Map.fromList . map (,slotId)

    wdc :: WalletDecrCredentials
    wdc = eskToWalletDecrCredentials esk
    wKey = (wid, wdc)

    inps :: [Map HdAccountId (Set TxIn)]
    outs :: [Map HdAccountId UtxoWithAddrId]
    (inps, outs) = unzip $ map (prefilterTx wKey) (block ^. rbTxs)

    inpAll :: Map HdAccountId (Set TxIn)
    outAll :: Map HdAccountId UtxoWithAddrId
    inpAll = Map.unionsWith Set.union inps
    outAll = Map.unionsWith Map.union outs

    slotId = block ^. rbSlot . fromDb
    accountIds = Map.keysSet inpAll `Set.union` Map.keysSet outAll

-- | Prefilter the inputs and outputs of a resolved transaction
prefilterTx :: WalletKey
            -> ResolvedTx
            -> (Map HdAccountId (Set TxIn), Map HdAccountId UtxoWithAddrId)
prefilterTx wKey tx = (
      prefilterInputs wKey (toList (tx ^. rtxInputs . fromDb))
    , prefilterUtxo'  wKey (tx ^. rtxOutputs . fromDb)
    )

-- | Prefilter inputs of a transaction
prefilterInputs :: WalletKey
          -> [(TxIn, ResolvedInput)]
          -> Map HdAccountId (Set TxIn)
prefilterInputs wKey inps
    = Map.fromListWith Set.union
      $ map f
      $ prefilterResolvedTxPairs wKey inps
    where
        f (addressId, (txIn, _txOut)) = (addressId ^. hdAddressIdParent, Set.singleton txIn)

-- | Prefilter utxo using wallet key
prefilterUtxo' :: WalletKey -> Utxo -> Map HdAccountId UtxoWithAddrId
prefilterUtxo' wid utxo
    = Map.fromListWith Map.union
      $ map f
      $ prefilterResolvedTxPairs wid (Map.toList utxo)
    where
        f (addressId, (txIn, txOut)) = (addressId ^. hdAddressIdParent,
                                        Map.singleton txIn (txOut, addressId))

-- | Prefilter utxo using walletId and esk
prefilterUtxo :: HdRootId -> EncryptedSecretKey -> Utxo -> Map HdAccountId (Utxo,[AddrWithId])
prefilterUtxo rootId esk utxo = map toPrefilteredUtxo' (prefilterUtxo' wKey utxo)
    where
        wKey = (WalletIdHdRnd rootId, eskToWalletDecrCredentials esk)

-- | Prefilter resolved transaction pairs
prefilterResolvedTxPairs :: WalletKey
                         -> [(TxIn, TxOutAux)]
                         -> [(HdAddressId, (TxIn, TxOutAux))]
prefilterResolvedTxPairs wid xs = map f $ prefilter wid selectAddr xs
    where
        f ((txIn, txOut), addressId) = (addressId, (txIn, txOut))
        selectAddr = txOutAddress . toaOut . snd

-- | Filter items for addresses that were derived from the given WalletKey.
--   Returns the matching HdAddressId, which embeds the parent HdAccountId
--   discovered for the matching item.
--
-- TODO(@uroboros/ryan) `selectOwnAddresses` calls `decryptAddress`, which extracts
-- the AccountId from the Tx Attributes. This is not sufficient since it
-- doesn't actually _verify_ that the Tx belongs to the AccountId.
-- We need to add verification (see `deriveLvl2KeyPair`).
prefilter :: WalletKey
     -> (a -> Address)      -- ^ address getter
     -> [a]                 -- ^ list to filter
     -> [(a, HdAddressId)]  -- ^ matching items
prefilter (wid,wdc) selectAddr rtxs
    = map f $ selectOwnAddresses wdc selectAddr rtxs
    where f (addr,meta) = (addr, toAddressId wid meta)

          toAddressId :: WalletId -> WAddressMeta -> HdAddressId
          toAddressId (WalletIdHdRnd rootId) meta' = addressId
              where
                  accountIx = HdAccountIx (_wamAccountIndex meta')
                  accountId = HdAccountId rootId accountIx

                  addressIx = HdAddressIx (_wamAddressIndex meta')
                  addressId = HdAddressId accountId addressIx

{-------------------------------------------------------------------------------
  Pretty-printing
-------------------------------------------------------------------------------}

instance Buildable PrefilteredBlock where
  build PrefilteredBlock{..} = bprint
    ( "PrefilteredBlock "
    % "{ inputs:  " % listJson
    % ", outputs: " % mapJson
    % "}"
    )
    (Set.toList pfbInputs)
    pfbOutputs
