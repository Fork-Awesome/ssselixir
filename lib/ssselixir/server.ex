# -*- coding: utf-8 -*-
#
# Copyright 2017 ssselixir
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
require Logger

defmodule SSSelixir.Server do
  use GenServer

  # def start_link(_args) do
  #   load_config()
  #   [{'port_password', port_password}] = :ets.lookup(:app_config, 'port_password')
  #   Enum.each(port_password, fn {port, password} ->
  #     Task.start(
  #       fn ->
  #         Logger.info "Start server on port: #{port}"
  #         loop_accept(listen(port), gen_key(password))
  #       end
  #     )
  #   end)
  #   {:ok, self()}
  # end

  def start_link(_args) do
    load_config()
    port_passwords = SSSelixir.PortPassword |> SSSelixir.Repo.all
    Enum.each(port_passwords, fn port_password ->
      Task.start(
        fn ->
          Logger.info "Start server on port: #{port_password.port}"
          loop_accept(listen(port_password.port), gen_key(port_password.password))
        end
      )
    end)
    {:ok, self()}
  end

  def start_handle(client) do
    Task.start(fn -> handle(client) end)
  end

  def start_loop_reply do
    Task.start_link(fn -> loop_reply() end)
  end

  def load_config do
    :ets.new(:app_config, [:named_table])
    :ets.insert(:app_config, {'port_password', fetch_setting('port_password')})
    :ets.insert(:app_config, {'timeout', fetch_setting('timeout')})
  end

  def fetch_setting(key) do
    case :yamerl_constr.file("config/app_config.yml") |> List.first |> List.keyfind(key, 0) do
      {key, data} ->
        Logger.info "Loading data"
        data
      _ ->
        Logger.error "Invalid configurations"
        Process.exit(self(), :kill)
    end
  end

  def listen(port) do
    opts = [:binary, active: false, reuseaddr: true]
    :gen_tcp.listen(port, opts)
  end

  def handle_accept(server, {:key, key}) do
    case accept(server) do
      {:ok, client} ->
        {:ok, {ip_addr, ip_port}} = :inet.peername(client)
        Logger.info "Client info: #{:inet.ntoa(ip_addr)}:#{ip_port}"
        {:ok, pid} = start_handle(client)
        send pid, {:key, key}
        {:ok, server}
      {:error, :emfile} -> {:error, :server_error}
    end
  end

  def loop_accept({:ok, server}=sevopts, key) do
    handle_accept(server, {:key, key})
    loop_accept(sevopts, key)
  end

  def accept(server) do
    :gen_tcp.accept(server)
  end

  def shutdown({:socket, socket}) do
    :gen_tcp.shutdown(socket, :read_write)
  end

  def create_remote_connection(addr, port) do
    [{'timeout', timeout}] = :ets.lookup(:app_config, 'timeout')
    opts = [:binary, active: false]
    :gen_tcp.connect(addr, port, opts, timeout * 1000)
  end

  def send_data(sock, data) do
    :gen_tcp.send(sock, data)
  end

  def recv_data(sock) do
    [{'timeout', timeout}] = :ets.lookup(:app_config, 'timeout')
    :gen_tcp.recv(sock, 0, timeout * 1000)
  end

  def init_encrypt_options({:key, key}) do
    %{key: key, iv: :crypto.strong_rand_bytes(16), rest: <<>>, iv_sent: false}
  end

  def parse_header(plain_data) do
    addrtype = plain_data |> binary_part(0, 1) |> to_i

    case addrtype do
      1 ->
        <<p1, p2, p3, p4>> = binary_part(plain_data, 1, 4)
        addr = :inet.ntoa({p1, p2, p3, p4})
        addrlen = 4
        port = plain_data |> binary_part(5, 2) |> to_i
        {:ok, addrtype, addrlen, addr, port}

      3 ->
        addrlen = plain_data |> binary_part(1, 1) |> to_i
        addr = plain_data |> binary_part(2, addrlen) |> to_charlist
        port = plain_data |> binary_part(2+addrlen, 2) |> to_i
        {:ok, addrtype, addrlen, addr, port}

      _ -> {:error, :invalid_header}
    end
  end

  def handle(sock) do
    receive do
      {:key, key} ->
        case recv_data(sock) do
          {:ok, encrypted_data} ->
            {plain_data, decrypt_options} =
              decrypt(encrypted_data, %{key: key, iv: <<>>, rest: <<>>})
            case parse_header(plain_data) do
              {:ok, addrtype, addrlen, addr, port} ->
                case create_remote_connection(addr, port) do
                  {:ok, remote} ->
                    Logger.info "Connect to #{addr}:#{port}"
                    rest_data =
                      if addrtype == 1 do
                        :binary.part(plain_data, 3+addrlen, byte_size(plain_data)-(3+addrlen))
                      else
                        :binary.part(plain_data, 4+addrlen, byte_size(plain_data)-(4+addrlen))
                      end
                    if byte_size(rest_data) > 0, do: send_data(remote, rest_data)
                    handle_tcp(sock, remote, decrypt_options, init_encrypt_options({:key, key}))

                  {:error, _} ->
                    shutdown({:socket, sock})
                    Logger.error "Connected failed or timeout"
                end
              {:error, :invalid_header} ->
                Logger.error "Invalid header"
                shutdown({:socket, sock})
            end
          {:error, _} ->
            Logger.error "Connected timeout or closed"
        end
      _ ->
        Logger.error "Wrong message received"
        shutdown({:socket, sock})
    end
  end

  def handle_tcp(client, remote, decrypt_options, encrypt_options) do
    {:ok, c2r_pid} = start_loop_reply()
    send c2r_pid, {:c2r, client, remote, decrypt_options, self()}
    {:ok, r2c_pid} = start_loop_reply()
    send r2c_pid, {:r2c, remote, client, encrypt_options, self()}
    receive do
      {:error, :closed} ->
        shutdown({:socket, client})
        shutdown({:socket, remote})
        Process.exit(c2r_pid, :kill)
        Process.exit(r2c_pid, :kill)
    end
  end

  def gen_key(seed) do
    dup_seed = to_string(seed)
    hashed_seed = :crypto.hash(:md5, dup_seed)
    hashed_seed <> :crypto.hash(:md5, hashed_seed <> dup_seed)
  end

  def encrypt(data, %{key: key, iv: iv, rest: rest, iv_sent: iv_sent}) do
    rest_len = byte_size(rest)
    data_len = byte_size(data)
    len = div((data_len + rest_len), 16) * 16
    <<data::binary-size(len), rest::binary>> = <<rest::binary, data::binary>>
    enc_data = :crypto.block_encrypt(:aes_cfb128, key, iv, data)
    new_iv = :binary.part(<<iv::binary, enc_data::binary>>, byte_size(enc_data)+16, -16)
    enc_rest = :crypto.block_encrypt(:aes_cfb128, key, new_iv, rest)
    encrypted_data = :binary.part(<<enc_data::binary, enc_rest::binary>>, rest_len, data_len)
    if iv_sent do
      { encrypted_data, %{key: key, iv: new_iv, rest: rest, iv_sent: iv_sent} }
    else
      { <<iv::binary, encrypted_data::binary>>, %{key: key, iv: new_iv, rest: rest, iv_sent: true}}
    end
  end

  def decrypt(data, %{key: key, iv: iv, rest: rest}) do
    if byte_size(iv) == 0 do
      iv = :binary.part(data, 0, 16)
      data = :binary.part(data, 16, byte_size(data)-16)
    end
    data_len = byte_size(data)
    rest_len = byte_size(rest)
    len = div((data_len+rest_len), 16) * 16
    <<data::binary-size(len), rest::binary>> = <<rest::binary, data::binary>>

    dec_data = :crypto.block_decrypt(:aes_cfb128, key, iv, data)
    iv = :binary.part(<<iv::binary, data::binary>>, byte_size(data)+16, -16)
    dec_rest = :crypto.block_decrypt(:aes_cfb128, key, iv, rest)
    decrypted_data = :binary.part(<<dec_data::binary, dec_rest::binary>>, rest_len, data_len)
    {decrypted_data, %{key: key, iv: iv, rest: rest}}
  end

  def loop_reply do
    receive do
      {:c2r, client, remote, decrypt_options, caller} ->
        reply(:c2r, client, remote, decrypt_options, caller)
      {:r2c, remote, client, encrypt_options, caller} ->
        reply(:r2c, remote, client, encrypt_options, caller)
    end
  end

  defp to_i(data) do
    data |> Base.encode16 |> String.to_integer(16)
  end

  defp reply(direction, from, to, crypto_options, caller) do
    case recv_data(from) do
      {:ok, data} ->
        case direction do
          :c2r ->
            {plain_data, decrypt_options} = decrypt(data, crypto_options)
            case send_data(to, plain_data) do
              :ok -> send(self(), {:c2r, from, to, decrypt_options, caller})
              {:error, _} ->
                send caller, {:error, :closed}
            end

          :r2c ->
            {encrypted_data, encrypt_options} = encrypt(data, crypto_options)
            case send_data(to, encrypted_data) do
              :ok -> send(self(), {:r2c, from, to, encrypt_options, caller})
              {:error, _} ->
                send caller, {:error, :closed}
            end
        end
        loop_reply()
      _ ->
        send caller, {:error, :closed}
    end
  end
end
