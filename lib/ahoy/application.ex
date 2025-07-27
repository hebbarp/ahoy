defmodule Ahoy.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Local registry for client processes
      {Registry, keys: :unique, name: Ahoy.ClientRegistry},
      
      # Registry for global user/channel state
      {Ahoy.Core.Registry, []},
      
      # Network discovery for finding other nodes
      {Ahoy.Core.Discovery, []},
      
      # Message router for handling inter-node communication
      {Ahoy.Core.Router, []},
      
      # Dynamic supervisor for client sessions
      {DynamicSupervisor, strategy: :one_for_one, name: Ahoy.ClientSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Ahoy.Supervisor]
    Supervisor.start_link(children, opts)
  end
end