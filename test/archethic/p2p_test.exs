defmodule Archethic.P2PTest do
  use ArchethicCase

  alias Archethic.Crypto

  alias Archethic.P2P
  alias Archethic.P2P.Node

  doctest Archethic.P2P

  import Mox

  setup :verify_on_exit!
  setup :set_mox_global

  test "get_node_info/0 should return retrieve local node information" do
    P2P.add_and_connect_node(%Node{
      ip: {127, 0, 0, 1},
      port: 3000,
      first_public_key: Crypto.last_node_public_key(),
      last_public_key: Crypto.last_node_public_key()
    })

    Process.sleep(100)

    assert %Node{ip: {127, 0, 0, 1}} = P2P.get_node_info()
  end
end
