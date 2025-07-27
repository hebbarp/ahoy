defmodule Ahoy.UI.App do
  @moduledoc """
  Simple command-line UI for Ahoy chat.
  Replaces Ratatouille with basic STDIN/STDOUT interaction.
  """
  
  require Logger

  def start(username, client_pid, _opts \\ []) do
    # Store username in process dictionary for display_message
    Process.put(:username, username)
    
    IO.puts("\n=== Ahoy Chat - #{username} ===")
    IO.puts("Type /help for commands, /quit to exit")
    IO.puts("Connecting to network...\n")
    
    # Start input loop
    input_loop(username, client_pid)
  end

  defp input_loop(username, client_pid) do
    # Start message receiver in parallel
    spawn_link(fn -> message_receiver_loop() end)
    
    # Main input loop
    input_loop_main(username, client_pid)
  end

  defp input_loop_main(username, client_pid) do
    case IO.gets("#{username}> ") do
      :eof ->
        IO.puts("\nGoodbye!")
        
      {:error, reason} ->
        IO.puts("Input error: #{inspect(reason)}")
        input_loop_main(username, client_pid)
        
      input when is_binary(input) ->
        trimmed = String.trim(input)
        
        case handle_input(trimmed, username, client_pid) do
          :quit -> 
            IO.puts("Goodbye!")
            System.halt(0)
          
          :continue -> 
            input_loop_main(username, client_pid)
        end
    end
  end

  # Handle incoming messages from Client
  defp message_receiver_loop() do
    receive do
      {:ui_message, message} ->
        display_message(message)
        message_receiver_loop()
      
      other ->
        IO.puts("Unknown UI message: #{inspect(other)}")
        message_receiver_loop()
    end
  end

  defp display_message(message) do
    case message do
      %{type: :channel_message, from: from, channel: channel, message: msg, timestamp: ts} ->
        time = format_timestamp(ts)
        IO.puts("\r[#{time}] #{channel} <#{from}> #{msg}")
        IO.write("#{Process.get(:username, "user")}> ")
      
      %{type: :direct_message, from: from, message: msg, timestamp: ts} ->
        time = format_timestamp(ts)
        IO.puts("\r[#{time}] DM from #{from}: #{msg}")
        IO.write("#{Process.get(:username, "user")}> ")
      
      %{type: :system_message, message: msg} ->
        IO.puts("\r* #{msg}")
        IO.write("#{Process.get(:username, "user")}> ")
      
      %{type: :error, message: msg} ->
        IO.puts("\rERROR: #{msg}")
        IO.write("#{Process.get(:username, "user")}> ")
      
      _ ->
        IO.puts("\rUnknown message: #{inspect(message)}")
        IO.write("#{Process.get(:username, "user")}> ")
    end
  end

  defp handle_input("", _username, _client_pid), do: :continue
  
  defp handle_input("/quit", _username, _client_pid), do: :quit
  
  defp handle_input("/help", _username, _client_pid) do
    IO.puts("""
    
    Available commands:
    /help              - Show this help
    /join #channel     - Join a channel
    /leave #channel    - Leave a channel  
    /msg user message  - Send direct message
    /who [#channel]    - List users
    /network           - Show network info
    /quit              - Exit Ahoy
    
    Regular text will be sent to your current channel.
    """)
    :continue
  end
  
  defp handle_input("/network", _username, _client_pid) do
    info = Ahoy.network_info()
    IO.puts("""
    
    Network Information:
    Own node: #{info.own_node}
    Connected nodes: #{inspect(info.connected_nodes)}
    Total cluster size: #{info.total_cluster_size}
    """)
    :continue
  end
  
  defp handle_input("/who", _username, _client_pid) do
    users = Ahoy.list_users()
    IO.puts("\nOnline users:")
    Enum.each(users, fn {username, info} ->
      channels = Enum.join(info.channels, ", ")
      IO.puts("  #{username}@#{info.node} - channels: [#{channels}]")
    end)
    IO.puts("")
    :continue
  end
  
  defp handle_input("/join " <> channel, username, client_pid) do
    channel = String.trim(channel)
    if String.starts_with?(channel, "#") do
      # Send join command to client
      case Ahoy.Core.Client.join_channel(client_pid, channel) do
        :ok ->
          IO.puts("Joined #{channel}")
        {:error, :already_in_channel} ->
          IO.puts("Already in #{channel}")
        {:error, reason} ->
          IO.puts("Failed to join #{channel}: #{inspect(reason)}")
      end
    else
      IO.puts("Channel names must start with #")
    end
    :continue
  end
  
  defp handle_input("/leave " <> channel, username, client_pid) do
    channel = String.trim(channel)
    # TODO: Send leave command to client
    IO.puts("Leaving #{channel}...")
    :continue
  end
  
  defp handle_input("/connect " <> node_name, _username, _client_pid) do
    node_name = String.trim(node_name)
    Ahoy.Core.Discovery.connect_to_node(String.to_atom(node_name))
    IO.puts("Connection attempt to #{node_name}")
    :continue
  end
  
  defp handle_input("/msg " <> rest, username, client_pid) do
    case String.split(rest, " ", parts: 2) do
      [to_user, message] ->
        # TODO: Send direct message via client
        IO.puts("Sending DM to #{to_user}: #{message}")
      
      _ ->
        IO.puts("Usage: /msg username message")
    end
    :continue
  end
  
  defp handle_input(message, username, client_pid) do
    # Regular message to current channel
    case Ahoy.Core.Client.send_message(client_pid, message) do
      :ok ->
        # Message sent successfully (no need to print, it will come back via Router)
        :continue
      
      {:error, reason} ->
        IO.puts("Failed to send message: #{inspect(reason)}")
        :continue
    end
  end

  # Handle incoming messages from Client process
  def handle_message(message) do
    case message do
      %{type: :channel_message, from: from, channel: channel, message: msg, timestamp: ts} ->
        time = format_timestamp(ts)
        IO.puts("[#{time}] #{channel} <#{from}> #{msg}")
      
      %{type: :direct_message, from: from, message: msg, timestamp: ts} ->
        time = format_timestamp(ts)
        IO.puts("[#{time}] DM from #{from}: #{msg}")
      
      %{type: :system_message, message: msg} ->
        IO.puts("* #{msg}")
      
      %{type: :error, message: msg} ->
        IO.puts("ERROR: #{msg}")
      
      _ ->
        IO.puts("Unknown message: #{inspect(message)}")
    end
  end

  defp format_timestamp(datetime) do
    datetime
    |> DateTime.to_time()
    |> Time.to_string()
    |> String.slice(0, 5)  # HH:MM
  end
end