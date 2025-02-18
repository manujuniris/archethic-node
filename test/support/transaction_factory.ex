defmodule Archethic.TransactionFactory do
  @moduledoc false

  alias Archethic.Crypto

  alias Archethic.Election

  alias Archethic.Mining.Fee

  alias Archethic.TransactionChain
  alias Archethic.TransactionChain.Transaction
  alias Archethic.TransactionChain.Transaction.CrossValidationStamp
  alias Archethic.TransactionChain.Transaction.ValidationStamp
  alias Archethic.TransactionChain.Transaction.ValidationStamp.LedgerOperations

  alias Archethic.TransactionChain.Transaction.ValidationStamp.LedgerOperations.TransactionMovement

  alias Archethic.TransactionChain.TransactionData

  def create_valid_transaction(
        inputs \\ [],
        opts \\ []
      ) do
    type = Keyword.get(opts, :type, :transfer)
    seed = Keyword.get(opts, :seed, "seed")
    index = Keyword.get(opts, :index, 0)
    content = Keyword.get(opts, :content, "")

    timestamp =
      Keyword.get(opts, :timestamp, DateTime.utc_now()) |> DateTime.truncate(:millisecond)

    tx = Transaction.new(type, %TransactionData{content: content}, seed, index)

    ledger_operations =
      %LedgerOperations{
        fee: Fee.calculate(tx, 0.07),
        transaction_movements: Transaction.get_movements(tx)
      }
      |> LedgerOperations.consume_inputs(tx.address, inputs)
      |> LedgerOperations.add_burning_movement()

    validation_stamp =
      %ValidationStamp{
        timestamp: timestamp,
        proof_of_work: Crypto.origin_node_public_key(),
        proof_of_election:
          Election.validation_nodes_election_seed_sorting(tx, DateTime.utc_now()),
        proof_of_integrity: TransactionChain.proof_of_integrity([tx]),
        ledger_operations: ledger_operations
      }
      |> ValidationStamp.sign()

    cross_validation_stamp = CrossValidationStamp.sign(%CrossValidationStamp{}, validation_stamp)
    %{tx | validation_stamp: validation_stamp, cross_validation_stamps: [cross_validation_stamp]}
  end

  def create_transaction_with_not_atomic_commitment(unspent_outputs \\ []) do
    tx = create_valid_transaction(unspent_outputs)

    cross_validation_stamp =
      CrossValidationStamp.sign(
        %CrossValidationStamp{inconsistencies: [:proof_of_work]},
        tx.validation_stamp
      )

    Map.update!(tx, :cross_validation_stamps, &[cross_validation_stamp | &1])
  end

  def create_valid_transaction_with_inconsistencies(inputs \\ []) do
    tx = Transaction.new(:transfer, %TransactionData{}, "seed", 0)

    ledger_operations =
      %LedgerOperations{
        fee: Fee.calculate(tx, 0.07)
      }
      |> LedgerOperations.consume_inputs(tx.address, inputs)
      |> LedgerOperations.add_burning_movement()

    validation_stamp =
      %ValidationStamp{
        timestamp: DateTime.utc_now(),
        proof_of_work: Crypto.origin_node_public_key(),
        proof_of_integrity: TransactionChain.proof_of_integrity([tx]),
        proof_of_election:
          Election.validation_nodes_election_seed_sorting(tx, DateTime.utc_now()),
        ledger_operations: ledger_operations
      }
      |> ValidationStamp.sign()

    cross_validation_stamp =
      CrossValidationStamp.sign(
        %CrossValidationStamp{inconsistencies: [:signature]},
        validation_stamp
      )

    %{tx | validation_stamp: validation_stamp, cross_validation_stamps: [cross_validation_stamp]}
  end

  def create_transaction_with_invalid_proof_of_work(inputs \\ []) do
    tx = Transaction.new(:transfer, %TransactionData{}, "seed", 0)

    ledger_operations =
      %LedgerOperations{
        fee: Fee.calculate(tx, 0.07)
      }
      |> LedgerOperations.add_burning_movement()
      |> LedgerOperations.consume_inputs(tx.address, inputs)

    validation_stamp = %ValidationStamp{
      timestamp: DateTime.utc_now(),
      proof_of_work: <<0, 0, :crypto.strong_rand_bytes(32)::binary>>,
      proof_of_integrity: TransactionChain.proof_of_integrity([tx]),
      proof_of_election: Election.validation_nodes_election_seed_sorting(tx, DateTime.utc_now()),
      ledger_operations: ledger_operations,
      signature: :crypto.strong_rand_bytes(32)
    }

    cross_validation_stamp =
      CrossValidationStamp.sign(
        %CrossValidationStamp{},
        validation_stamp
      )

    %{tx | validation_stamp: validation_stamp, cross_validation_stamps: [cross_validation_stamp]}
  end

  def create_transaction_with_invalid_proof_of_election(inputs \\ []) do
    tx = Transaction.new(:transfer, %TransactionData{}, "seed", 0)

    ledger_operations =
      %LedgerOperations{
        fee: Fee.calculate(tx, 0.07)
      }
      |> LedgerOperations.add_burning_movement()
      |> LedgerOperations.consume_inputs(tx.address, inputs)

    validation_stamp =
      %ValidationStamp{
        timestamp: DateTime.utc_now(),
        proof_of_work: Crypto.origin_node_public_key(),
        proof_of_integrity: TransactionChain.proof_of_integrity([tx]),
        proof_of_election: :crypto.strong_rand_bytes(32),
        ledger_operations: ledger_operations,
        signature: :crypto.strong_rand_bytes(32)
      }
      |> ValidationStamp.sign()

    cross_validation_stamp =
      CrossValidationStamp.sign(
        %CrossValidationStamp{},
        validation_stamp
      )

    %{tx | validation_stamp: validation_stamp, cross_validation_stamps: [cross_validation_stamp]}
  end

  def create_transaction_with_invalid_validation_stamp_signature(inputs \\ []) do
    tx = Transaction.new(:transfer, %TransactionData{}, "seed", 0)

    ledger_operations =
      %LedgerOperations{
        fee: Fee.calculate(tx, 0.07)
      }
      |> LedgerOperations.add_burning_movement()
      |> LedgerOperations.consume_inputs(tx.address, inputs)

    validation_stamp = %ValidationStamp{
      timestamp: DateTime.utc_now(),
      proof_of_work: Crypto.origin_node_public_key(),
      proof_of_integrity: TransactionChain.proof_of_integrity([tx]),
      proof_of_election: Election.validation_nodes_election_seed_sorting(tx, DateTime.utc_now()),
      ledger_operations: ledger_operations,
      signature: :crypto.strong_rand_bytes(32)
    }

    cross_validation_stamp =
      CrossValidationStamp.sign(
        %CrossValidationStamp{},
        validation_stamp
      )

    %{tx | validation_stamp: validation_stamp, cross_validation_stamps: [cross_validation_stamp]}
  end

  def create_transaction_with_invalid_fee(inputs \\ []) do
    tx = Transaction.new(:transfer, %TransactionData{}, "seed", 0)

    ledger_operations =
      %LedgerOperations{
        fee: 1_000_000_000
      }
      |> LedgerOperations.add_burning_movement()
      |> LedgerOperations.consume_inputs(tx.address, inputs)

    validation_stamp =
      %ValidationStamp{
        timestamp: DateTime.utc_now(),
        proof_of_work: Crypto.origin_node_public_key(),
        proof_of_election:
          Election.validation_nodes_election_seed_sorting(tx, DateTime.utc_now()),
        proof_of_integrity: TransactionChain.proof_of_integrity([tx]),
        ledger_operations: ledger_operations
      }
      |> ValidationStamp.sign()

    cross_validation_stamp =
      CrossValidationStamp.sign(
        %CrossValidationStamp{},
        validation_stamp
      )

    %{tx | validation_stamp: validation_stamp, cross_validation_stamps: [cross_validation_stamp]}
  end

  def create_transaction_with_invalid_transaction_movements(inputs \\ []) do
    tx = Transaction.new(:transfer, %TransactionData{}, "seed", 0)

    ledger_operations =
      %LedgerOperations{
        fee: Fee.calculate(tx, 0.07),
        transaction_movements: [
          %TransactionMovement{to: "@Bob4", amount: 30_330_000_000, type: :UCO}
        ]
      }
      |> LedgerOperations.consume_inputs(tx.address, inputs)

    validation_stamp =
      %ValidationStamp{
        timestamp: DateTime.utc_now(),
        proof_of_work: Crypto.origin_node_public_key(),
        proof_of_integrity: TransactionChain.proof_of_integrity([tx]),
        proof_of_election:
          Election.validation_nodes_election_seed_sorting(tx, DateTime.utc_now()),
        ledger_operations: ledger_operations
      }
      |> ValidationStamp.sign()

    cross_validation_stamp =
      CrossValidationStamp.sign(
        %CrossValidationStamp{},
        validation_stamp
      )

    %{tx | validation_stamp: validation_stamp, cross_validation_stamps: [cross_validation_stamp]}
  end
end
