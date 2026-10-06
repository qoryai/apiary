defmodule Apiary.Integrations.Fetch.AddressTest do
  use ExUnit.Case, async: true

  alias Apiary.Integrations.Fetch.Address

  defp class(text) do
    {:ok, ip} = text |> String.to_charlist() |> :inet.parse_address()
    Address.classify(ip)
  end

  test "forbidden: no server's address" do
    for ip <- ~w(0.0.0.0 127.0.0.1 127.8.9.1 169.254.169.254 169.254.1.1 100.100.100.200 224.0.0.1
                 240.0.0.1 255.255.255.255 :: ::1 fe80::1 ff02::1 fd00:ec2::254 ::ffff:127.0.0.1
                 ::ffff:169.254.169.254 64:ff9b::a9fe:a9fe 2002:7f00:1::1),
        do: assert(class(ip) == :forbidden, ip)
  end

  test "forbidden: every metadata address of the clouds, however it is written" do
    for ip <- ~w(192.0.0.192 ::ffff:192.0.0.192 fd00:ec2::254 fd00:ec2::23 fd00:ec2::1
                 fd00:ec2:ffff::1 64:ff9b:1::a9fe:a9fe 64:ff9b:1:2:3:4:7f00:1),
        do: assert(class(ip) == :forbidden, ip)
  end

  test "private: a network's own" do
    for ip <- ~w(10.0.0.1 172.16.0.1 172.31.255.255 192.168.1.1 100.64.0.1 198.18.0.1 192.0.0.8
                 192.0.0.193 fd12:3456::1 fc00::1 fd00:ec3::1 ::ffff:10.0.0.1 2001::1
                 64:ff9b:1::a00:1),
        do: assert(class(ip) == :private, ip)
  end

  test "public" do
    for ip <-
          ~w(203.0.113.10 8.8.8.8 172.32.0.1 100.128.0.1 2001:db8::10 2606:4700::1 ::ffff:203.0.113.10
             64:ff9b:1::cb00:710a),
        do: assert(class(ip) == :public, ip)
  end
end
