defmodule Archethic.OracleChain.Scheduler do
  @moduledoc """
  Manage the scheduling of the oracle transactions
  """

  alias Archethic.Crypto

  alias Archethic.Election

  alias Archethic.P2P
  alias Archethic.P2P.Node

  alias Archethic.PubSub

  alias Archethic.OracleChain.Services
  alias Archethic.OracleChain.Summary

  alias Archethic.TransactionChain
  alias Archethic.TransactionChain.Transaction
  alias Archethic.TransactionChain.TransactionData

  alias Crontab.CronExpression.Parser, as: CronParser
  alias Crontab.Scheduler, as: CronScheduler

  use GenStateMachine, callback_mode: [:handle_event_function]

  require Logger

  def start_link(args \\ [], opts \\ [name: __MODULE__]) do
    GenStateMachine.start_link(__MODULE__, args, opts)
  end

  @doc """
  Retrieve the summary interval
  """
  @spec get_summary_interval :: binary()
  def get_summary_interval do
    GenStateMachine.call(__MODULE__, :summary_interval)
  end

  @doc """
  Notify the scheduler about the replication of an oracle transaction
  """
  @spec ack_transaction(DateTime.t()) :: :ok
  def ack_transaction(timestamp = %DateTime{}) do
    GenStateMachine.cast(__MODULE__, {:inc_index, timestamp})
  end

  def config_change(nil), do: :ok

  def config_change(conf) do
    GenStateMachine.cast(__MODULE__, {:new_conf, conf})
  end

  def init(args) do
    polling_interval = Keyword.fetch!(args, :polling_interval)
    summary_interval = Keyword.fetch!(args, :summary_interval)

    PubSub.register_to_node_update()

    current_time = DateTime.utc_now() |> DateTime.truncate(:second)
    polling_date = next_date(polling_interval, current_time)
    summary_date = next_date(summary_interval, current_time)

    case P2P.get_node_info(Crypto.first_node_public_key()) do
      # Schedule polling for authorized node
      # This case may happen in case of process restart after crash
      {:ok, %Node{authorized?: true}} ->
        polling_timer = schedule_new_polling(polling_date, current_time)

        {:ok, :ready,
         %{
           polling_interval: polling_interval,
           polling_date: polling_date,
           summary_interval: summary_interval,
           summary_date: summary_date,
           indexes: %{summary_date => chain_size(summary_date)},
           polling_timer: polling_timer
         }}

      _ ->
        {:ok, :idle,
         %{
           polling_interval: polling_interval,
           polling_date: polling_date,
           summary_interval: summary_interval,
           summary_date: summary_date,
           indexes: %{}
         }}
    end
  end

  def handle_event(
        :cast,
        {:inc_index, timestamp},
        :ready,
        data = %{summary_interval: summary_interval, indexes: indexes}
      ) do
    next_summary_date = next_date(summary_interval, timestamp)

    case Map.get(indexes, next_summary_date) do
      nil ->
        # The scheduler is in ready (aka started) but it's not in a summary cycle
        :keep_state_and_data

      index ->
        new_data = Map.update!(data, :indexes, &Map.put(&1, next_summary_date, index + 1))
        Logger.debug("Next state #{inspect(new_data)}")
        {:keep_state, new_data}
    end
  end

  def handle_event(
        :info,
        :poll,
        :ready,
        data = %{
          polling_date: polling_date,
          summary_date: summary_date
        }
      ) do
    if DateTime.diff(polling_date, summary_date, :second) == 0 do
      {:next_state, :summary, data, {:next_event, :internal, :aggregate}}
    else
      {:next_state, :polling, data, {:next_event, :internal, :fetch_data}}
    end
  end

  def handle_event(
        :internal,
        :fetch_data,
        :polling,
        data = %{
          polling_interval: polling_interval,
          summary_date: summary_date,
          indexes: indexes
        }
      ) do
    Logger.debug("Oracle Poll - state: #{inspect(data)}")

    index = Map.fetch!(indexes, summary_date)

    if trigger_node?(summary_date, index + 1) do
      new_oracle_data =
        summary_date
        |> Crypto.derive_oracle_address(index)
        |> get_oracle_data()
        |> Services.fetch_new_data()

      if Enum.empty?(new_oracle_data) do
        Logger.debug("Oracle transaction skipped - no new data")
      else
        send_polling_transaction(new_oracle_data, index, summary_date)
      end
    else
      Logger.debug("Oracle transaction skipped - not the trigger node")
    end

    current_time = DateTime.utc_now() |> DateTime.truncate(:second)
    next_polling_date = next_date(polling_interval, current_time)

    new_data =
      data
      |> Map.put(:polling_date, next_polling_date)
      |> Map.put(:polling_timer, schedule_new_polling(next_polling_date, current_time))

    {:next_state, :ready, new_data}
  end

  def handle_event(
        :internal,
        :aggregate,
        :summary,
        data = %{summary_date: summary_date, summary_interval: summary_interval, indexes: indexes}
      )
      when is_map_key(indexes, summary_date) do
    Logger.debug("Oracle summary - state: #{inspect(data)}")

    index = Map.fetch!(indexes, summary_date)

    if trigger_node?(summary_date, index + 1) do
      Logger.debug("Oracle transaction summary sending")
      send_summary_transaction(summary_date, index)
    else
      Logger.debug("Oracle summary skipped - not the trigger node")
    end

    current_time = DateTime.utc_now() |> DateTime.truncate(:second)
    next_summary_date = next_date(summary_interval, current_time)
    Logger.info("Next Oracle Summary at #{DateTime.to_string(next_summary_date)}")

    new_data =
      data
      |> Map.put(:summary_date, next_summary_date)
      |> Map.update!(:indexes, fn indexes ->
        # Clean previous indexes
        indexes
        |> Map.keys()
        |> Enum.filter(&(DateTime.diff(&1, next_summary_date) < 0))
        |> Enum.reduce(indexes, &Map.delete(&2, &1))
      end)
      |> Map.update!(:indexes, fn indexes ->
        # Prevent overwrite, if the oracle transaction was faster than the summary processing
        if Map.has_key?(indexes, next_summary_date) do
          indexes
        else
          Map.put(indexes, next_summary_date, 0)
        end
      end)

    {:next_state, :polling, new_data, {:next_event, :internal, :fetch_data}}
  end

  def handle_event(:internal, :aggregate, :summary, data = %{summary_interval: summary_interval}) do
    # Discard the oracle summary if there is not previous indexing

    current_time = DateTime.utc_now() |> DateTime.truncate(:second)
    next_summary_date = next_date(summary_interval, current_time)
    Logger.info("Next Oracle Summary at #{DateTime.to_string(next_summary_date)}")

    new_data =
      data
      |> Map.put(:summary_date, next_summary_date)
      |> Map.put(:indexes, %{next_summary_date => 0})

    {:next_state, :polling, new_data, {:next_event, :internal, :fetch_data}}
  end

  def handle_event(
        :info,
        {:node_update,
         %Node{authorized?: true, available?: true, first_public_key: first_public_key}},
        _state,
        data = %{polling_interval: polling_interval, summary_interval: summary_interval}
      ) do
    with ^first_public_key <- Crypto.first_node_public_key(),
         nil <- Map.get(data, :polling_timer) do
      current_time = DateTime.utc_now() |> DateTime.truncate(:second)

      next_summary_date = next_date(summary_interval, current_time)

      other_authorized_nodes =
        P2P.authorized_and_available_nodes()
        |> Enum.reject(&(&1.first_public_key == first_public_key))

      new_data =
        case other_authorized_nodes do
          [] ->
            next_polling_date = next_date(polling_interval, current_time)
            polling_timer = schedule_new_polling(next_polling_date, current_time)

            data
            |> Map.put(:polling_timer, polling_timer)
            |> Map.put(:polling_date, next_polling_date)
            |> Map.put(:summary_date, next_summary_date)
            |> Map.put(:indexes, %{next_summary_date => chain_size(next_summary_date)})

          _ ->
            # Start the polling after the next summary, if there are already authorized nodes
            polling_timer = schedule_new_polling(next_summary_date, current_time)

            data
            |> Map.put(:polling_timer, polling_timer)
            |> Map.put(:polling_date, next_summary_date)
            |> Map.put(:summary_date, next_summary_date)
        end

      Logger.info("Start the Oracle scheduler")
      {:next_state, :ready, new_data}
    else
      _ ->
        :keep_state_and_data
    end
  end

  def handle_event(
        :info,
        {:node_update, %Node{authorized?: false, first_public_key: first_public_key}},
        _state,
        data = %{polling_timer: polling_timer}
      ) do
    if first_public_key == Crypto.first_node_public_key() do
      Process.cancel_timer(polling_timer)

      new_data =
        data
        |> Map.delete(:polling_timer)

      {:keep_state, new_data}
    else
      :keep_state_and_data
    end
  end

  def handle_event(
        :info,
        {:node_update,
         %Node{authorized?: true, available?: false, first_public_key: first_public_key}},
        _state,
        data = %{polling_timer: polling_timer}
      ) do
    if first_public_key == Crypto.first_node_public_key() do
      Process.cancel_timer(polling_timer)

      new_data =
        data
        |> Map.delete(:polling_timer)

      {:keep_state, new_data}
    else
      :keep_state_and_data
    end
  end

  def handle_event(:info, {:node_update, _}, _state, _data),
    do: :keep_state_and_data

  def handle_event(
        :cast,
        {:new_conf, conf},
        _,
        data = %{
          polling_interval: old_polling_interval,
          summary_interval: old_summary_interval
        }
      ) do
    summary_interval =
      case Keyword.get(conf, :summary_interval) do
        nil ->
          old_summary_interval

        new_interval ->
          new_interval
      end

    polling_interval =
      case Keyword.get(conf, :polling_interval) do
        nil ->
          old_polling_interval

        new_interval ->
          new_interval
      end

    new_data =
      data
      |> Map.put(:polling_interval, polling_interval)
      |> Map.put(:summary_interval, summary_interval)

    {:keep_state, new_data}
  end

  def handle_event(
        {:call, from},
        :summary_interval,
        _state,
        _data = %{summary_interval: summary_interval}
      ) do
    {:keep_state_and_data, {:reply, from, summary_interval}}
  end

  def handle_event(_event_type, _event, :idle, _data), do: :keep_state_and_data

  defp schedule_new_polling(next_polling_date, current_time = %DateTime{}) do
    Logger.info("Next oracle polling at #{DateTime.to_string(next_polling_date)}")

    Process.send_after(
      self(),
      :poll,
      DateTime.diff(next_polling_date, current_time, :millisecond)
    )
  end

  defp trigger_node?(summary_date = %DateTime{}, index) do
    authorized_nodes = P2P.authorized_nodes(summary_date) |> Enum.filter(& &1.available?)

    storage_nodes =
      summary_date
      |> Crypto.derive_oracle_address(index)
      |> Election.storage_nodes(authorized_nodes)

    node_public_key = Crypto.first_node_public_key()

    case storage_nodes do
      [%Node{first_public_key: ^node_public_key} | _] ->
        true

      _ ->
        false
    end
  end

  defp send_polling_transaction(oracle_data, index, summary_date) do
    {prev_pub, prev_pv} = Crypto.derive_oracle_keypair(summary_date, index)

    {next_pub, _} = Crypto.derive_oracle_keypair(summary_date, index + 1)

    tx =
      Transaction.new_with_keys(
        :oracle,
        %TransactionData{
          content: Jason.encode!(oracle_data),
          code: ~S"""
          condition inherit: [
            # We need to ensure the type stays consistent
            # So we can apply specific rules during the transaction validation
            type: in?([oracle, oracle_summary]),

            # We discard the content and code verification
            content: true,

            # We ensure the code stay the same
            code: if type == oracle_summary do
              regex_match?("condition inherit: \\[[\\s].*content: \\\"\\\"[\\s].*]")
            else
              previous.code
            end
          ]
          """
        },
        prev_pv,
        prev_pub,
        next_pub
      )

    Task.start(fn -> Archethic.send_new_transaction(tx) end)

    Logger.debug("New data pushed to the oracle",
      transaction_address: Base.encode16(tx.address),
      transaction_type: :oracle
    )
  end

  defp send_summary_transaction(summary_date, index) do
    oracle_chain =
      summary_date
      |> Crypto.derive_oracle_address(index)
      |> get_chain()

    {prev_pub, prev_pv} = Crypto.derive_oracle_keypair(summary_date, index)
    {next_pub, _} = Crypto.derive_oracle_keypair(summary_date, index + 1)

    aggregated_content =
      %Summary{transactions: oracle_chain}
      |> Summary.aggregate()
      |> Summary.aggregated_to_json()

    tx =
      Transaction.new_with_keys(
        :oracle_summary,
        %TransactionData{
          code: """
            # We stop the inheritance of transaction by ensuring no other
            # summary transaction will continue on this chain
            condition inherit: [ content: "" ]
          """,
          content: aggregated_content
        },
        prev_pv,
        prev_pub,
        next_pub
      )

    Logger.debug(
      "Sending oracle summary transaction - aggregation: #{inspect(aggregated_content)}",
      transaction_address: Base.encode16(tx.address),
      transaction_type: :oracle_summary
    )

    Task.start(fn -> Archethic.send_new_transaction(tx) end)
  end

  defp get_chain(address, opts \\ [], acc \\ []) do
    case TransactionChain.get(address, [data: [:content], validation_stamp: [:timestamp]], opts) do
      {transactions, false, _paging_state} ->
        acc ++ transactions

      {transactions, true, paging_state} ->
        get_chain(address, [paging_state: paging_state], acc ++ transactions)
    end
  end

  defp chain_size(summary_date = %DateTime{}) do
    summary_date
    |> Crypto.derive_oracle_address(0)
    |> TransactionChain.get_last_address()
    |> TransactionChain.size()
  end

  defp get_oracle_data(address) do
    case TransactionChain.get_transaction(address, data: [:content]) do
      {:ok, %Transaction{data: %TransactionData{content: previous_content}}} ->
        Jason.decode!(previous_content)

      _ ->
        %{}
    end
  end

  defp next_date(interval, from_date = %DateTime{}) do
    cron_expression = CronParser.parse!(interval, true)
    naive_from_date = from_date |> DateTime.truncate(:second) |> DateTime.to_naive()

    if Crontab.DateChecker.matches_date?(cron_expression, naive_from_date) do
      cron_expression
      |> CronScheduler.get_next_run_dates(naive_from_date)
      |> Enum.at(1)
      |> DateTime.from_naive!("Etc/UTC")
    else
      cron_expression
      |> CronScheduler.get_next_run_date!(naive_from_date)
      |> DateTime.from_naive!("Etc/UTC")
    end
  end
end
