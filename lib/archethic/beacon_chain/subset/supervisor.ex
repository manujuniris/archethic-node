defmodule Archethic.BeaconChain.SubsetSupervisor do
  @moduledoc false

  use Supervisor

  alias Archethic.BeaconChain
  alias Archethic.BeaconChain.Subset
  alias Archethic.BeaconChain.Subset.SummaryCache

  alias Archethic.Utils

  def start_link(arg \\ []) do
    Supervisor.start_link(__MODULE__, arg)
  end

  def init(_) do
    subset_children = subset_child_specs(BeaconChain.list_subsets())

    children = [
      {Registry,
       keys: :unique, name: BeaconChain.SubsetRegistry, partitions: System.schedulers_online()},
      SummaryCache | Utils.configurable_children(subset_children)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp subset_child_specs(subsets) do
    Enum.map(
      subsets,
      &{Subset, [subset: &1], id: {Subset, &1}}
    )
  end
end
