defmodule ArchethicWeb.TransactionDetailsLive do
  @moduledoc false
  use ArchethicWeb, :live_view

  alias Phoenix.View

  alias Archethic.Crypto

  alias Archethic.PubSub

  alias Archethic.TransactionChain.Transaction

  alias ArchethicWeb.ExplorerView

  alias Archethic.OracleChain

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket, %{
       exists: false,
       previous_address: nil,
       transaction: nil,
       inputs: [],
       calls: []
     })}
  end

  def handle_params(opts = %{"address" => address}, _uri, socket) do
    with {:ok, addr} <- Base.decode16(address, case: :mixed),
         true <- Crypto.valid_address?(addr) do
      case get_transaction(addr, opts) do
        {:ok, tx} ->
          {:noreply, handle_transaction(socket, tx)}

        {:error, :transaction_not_exists} ->
          PubSub.register_to_new_transaction_by_address(addr)
          {:noreply, handle_not_existing_transaction(socket, addr)}

        {:error, :transaction_invalid} ->
          {:noreply, handle_invalid_transaction(socket, addr)}
      end
    else
      _ ->
        {:noreply, handle_invalid_address(socket, address)}
    end
  end

  def handle_info({:new_transaction, address}, socket) do
    {:ok, tx} = get_transaction(address, %{})

    new_socket =
      socket
      |> assign(:ko?, false)
      |> handle_transaction(tx)

    {:noreply, new_socket}
  end

  def handle_info(_, socket) do
    {:noreply, socket}
  end

  def render(assigns = %{ko?: true}) do
    View.render(ExplorerView, "ko_transaction.html", assigns)
  end

  def render(assigns) do
    View.render(ExplorerView, "transaction_details.html", assigns)
  end

  defp get_transaction(address, %{"address" => "true"}) do
    Archethic.get_last_transaction(address)
  end

  defp get_transaction(address, _opts = %{}) do
    Archethic.search_transaction(address)
  end

  defp handle_transaction(
         socket,
         tx = %Transaction{address: address}
       ) do
    previous_address = Transaction.previous_address(tx)

    with {:ok, balance} <- Archethic.get_balance(address),
         {:ok, inputs} <- Archethic.get_transaction_inputs(address) do
      ledger_inputs = Enum.reject(inputs, &(&1.type == :call))
      contract_inputs = Enum.filter(inputs, &(&1.type == :call))
      uco_price_at_time = tx.validation_stamp.timestamp |> OracleChain.get_uco_price()
      uco_price_now = DateTime.utc_now() |> OracleChain.get_uco_price()

      socket
      |> assign(:transaction, tx)
      |> assign(:previous_address, previous_address)
      |> assign(:balance, balance)
      |> assign(:inputs, ledger_inputs)
      |> assign(:calls, contract_inputs)
      |> assign(:address, address)
      |> assign(:uco_price_at_time, uco_price_at_time)
      |> assign(:uco_price_now, uco_price_now)
    else
      {:error, :network_issue} ->
        socket
        |> assign(:error, :network_issue)
        |> assign(:address, address)
    end
  end

  defp handle_not_existing_transaction(socket, address) do
    case Archethic.get_transaction_inputs(address) do
      {:ok, inputs} ->
        ledger_inputs = Enum.reject(inputs, &(&1.type == :call))
        contract_inputs = Enum.filter(inputs, &(&1.type == :call))

        socket
        |> assign(:address, address)
        |> assign(:inputs, ledger_inputs)
        |> assign(:calls, contract_inputs)
        |> assign(:error, :not_exists)

      {:error, :network_issue} ->
        socket
        |> assign(:address, address)
        |> assign(:error, :network_issue)
    end
  end

  defp handle_invalid_address(socket, address) do
    socket
    |> assign(:address, address)
    |> assign(:error, :invalid_address)
  end

  defp handle_invalid_transaction(socket, address) do
    socket
    |> assign(:address, address)
    |> assign(:ko?, true)
  end
end
