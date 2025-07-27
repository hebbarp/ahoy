defmodule Ahoy do
  @moduledoc """
  Ahoy - A distributed IRC-like chat application built with Elixir/OTP.
  
  Features:
  - Peer-to-peer messaging using distributed Erlang
  - Automatic node discovery via UDP broadcast
  - Terminal UI with Ratatouille
  - No external dependencies
  """

  @doc """
  Start an Ahoy client session.
  """
  def start_client(username, opts \\ []) do
    # Start the client GenServer first
    case DynamicSupervisor.start_child(
      Ahoy.ClientSupervisor, 
      %{
        id: Ahoy.Core.Client,
        start: {Ahoy.Core.Client, :start_link, [username, self()]}
      }
    ) do
      {:ok, client_pid} -> 
        # Start the UI app with client PID
        ui_pid = spawn_link(fn -> 
          Ahoy.UI.App.start(username, client_pid, opts)
        end)
        
        # Send UI PID to client
        send(client_pid, {:ui_pid, ui_pid})
        
        {:ok, client_pid, ui_pid}
      error -> 
        error
    end
  end

  @doc """
  Get network information for the current node.
  """
  def network_info() do
    Ahoy.Core.Discovery.get_network_info()
  end

  @doc """
  List all connected users across the network.
  """
  def list_users() do
    Ahoy.Core.Registry.get_users()
  end

  @doc """
  Force a network discovery broadcast.
  """
  def discover_nodes() do
    Ahoy.Core.Discovery.force_discovery()
  end
end