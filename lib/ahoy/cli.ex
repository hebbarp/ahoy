defmodule Ahoy.CLI do
  @moduledoc """
  Command-line interface for Ahoy chat application.
  
  Usage:
    ./ahoy --name alice@hostname --cookie secretcookie
    ./ahoy --help
  """

  def main(args) do
    # Parse args first to get node info
    case parse_args(args) do
      {:start, username, opts} ->
        # Start distributed node immediately
        setup_node(opts[:name], opts[:cookie])
        handle_command({:start, username, opts})
      
      other ->
        handle_command(other)
    end
  end

  defp parse_args(args) do
    {opts, _argv, _} = OptionParser.parse(args,
      switches: [
        name: :string,
        cookie: :string,
        help: :boolean
      ],
      aliases: [
        n: :name,
        c: :cookie,
        h: :help
      ]
    )

    case {opts[:help], opts[:name]} do
      {true, _} -> 
        :help
      
      {_, nil} -> 
        {:error, "Missing required --name parameter"}
      
      {_, name} -> 
        username = extract_username(name)
        {:start, username, opts}
    end
  end

  defp handle_command(:help) do
    IO.puts("""
    Ahoy - Distributed IRC-like Chat

    Usage:
      ./ahoy --name USERNAME@HOSTNAME [--cookie COOKIE]

    Options:
      --name, -n     Node name (required) - format: username@hostname
      --cookie, -c   Erlang cookie for node authentication
      --help, -h     Show this help

    Examples:
      ./ahoy --name alice@laptop
      ./ahoy --name bob@desktop --cookie mycompany

    Commands in chat:
      /join #channel     Join a channel
      /leave #channel    Leave a channel
      /msg user message  Send direct message
      /who [#channel]    List users
      /quit              Exit
    """)
  end

  defp handle_command({:error, message}) do
    IO.puts("Error: #{message}")
    IO.puts("Use --help for usage information")
    System.halt(1)
  end

  defp handle_command({:start, username, opts}) do
    IO.puts("Starting Ahoy for #{username}...")
    IO.puts("Node: #{Node.self()}")
    IO.puts("Debug - extracted username: '#{username}' from node name: '#{opts[:name]}'")
    
    # Start the OTP application
    case Application.ensure_all_started(:ahoy) do
      {:ok, _} ->
        IO.puts("✓ Ahoy services started")
        
        # Start client session
        case Ahoy.start_client(username) do
          {:ok, _client_pid, _ui_pid} ->
            IO.puts("✓ Connected as #{username}")
            # Keep process alive
            Process.sleep(:infinity)
            
          {:error, reason} ->
            IO.puts("✗ Failed to start client: #{inspect(reason)}")
            System.halt(1)
        end
        
      {:error, reason} ->
        IO.puts("✗ Failed to start Ahoy: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp setup_node(node_name, cookie) do
    # Start distributed Erlang
    case Node.start(String.to_atom(node_name), :longnames) do
      :ok -> 
        IO.puts("✓ Node started: #{Node.self()}")
      
      {:ok, _pid} ->
        IO.puts("✓ Node started: #{Node.self()}")
      
      {:error, reason} -> 
        IO.puts("✗ Failed to start node: #{inspect(reason)}")
        System.halt(1)
    end
    
    # Set cookie if provided
    if cookie do
      Node.set_cookie(String.to_atom(cookie))
      IO.puts("✓ Cookie set")
    end
  end

  defp extract_username(node_name) do
    case String.split(node_name, "@") do
      [username, _host] -> username
      _ -> "unknown"
    end
  end
end