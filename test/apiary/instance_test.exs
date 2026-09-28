defmodule Apiary.InstanceTest do
  # Not async: `boot!/0` fixes the setting of the whole node, which every invitation reads.
  use ExUnit.Case, async: false

  alias Apiary.Instance

  @keys ~w(invitations_per_day_setting invitations_per_day)a

  setup do
    previous = Map.new(@keys, &{&1, Application.fetch_env(:apiary, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:apiary, key, value)
          :error -> Application.delete_env(:apiary, key)
        end
      end
    end)

    Application.delete_env(:apiary, :invitations_per_day_setting)
    :ok
  end

  describe "INVITATIONS_PER_DAY" do
    test "a whole number from 1, 20 when unset or blank" do
      assert Instance.parse_invitations_per_day(nil) == {:ok, 20}
      assert Instance.parse_invitations_per_day(" ") == {:ok, 20}
      assert Instance.parse_invitations_per_day("1") == {:ok, 1}
      assert Instance.parse_invitations_per_day(" 500 ") == {:ok, 500}

      for value <- ["0", "-1", "twenty", "2.5", "20 a day"] do
        assert {:error, reason} = Instance.parse_invitations_per_day(value)
        assert reason =~ "whole number"
      end
    end

    test "a value refused stops the boot; one accepted is the limit" do
      Application.put_env(:apiary, :invitations_per_day_setting, "0")
      assert_raise ArgumentError, ~r/INVITATIONS_PER_DAY/, fn -> Instance.boot!() end

      Application.put_env(:apiary, :invitations_per_day_setting, "50")
      assert Instance.boot!() == 50
      assert Instance.invitations_per_day() == 50

      Application.delete_env(:apiary, :invitations_per_day_setting)
      assert Instance.boot!() == 20
    end
  end
end
