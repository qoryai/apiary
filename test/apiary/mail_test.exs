defmodule Apiary.MailTest do
  use ExUnit.Case, async: true

  alias Apiary.Mail

  describe "source/0 and configured?/0" do
    test "the tests' Swoosh test adapter is mail set by the environment" do
      assert Mail.source() == :env
      assert Mail.configured?()
      assert Mail.mailer_config()[:adapter] == Swoosh.Adapters.Test
    end

    test "an adapter in the environment is :env; none is :none" do
      assert Mail.env_source(adapter: Swoosh.Adapters.Test) == :env
      # Development's.
      assert Mail.env_source(adapter: Swoosh.Adapters.Local) == :env
      assert Mail.env_source(adapter: Swoosh.Adapters.SMTP, relay: "smtp.example.com") == :env
      # Production's without SMTP_RELAY (config/runtime.exs).
      assert Mail.env_source(adapter: nil) == :none
      assert Mail.env_source([]) == :none
    end

    test "each source a test sets" do
      Mail.put_test_source(:none)
      assert Mail.source() == :none
      refute Mail.configured?()
      assert Mail.mailer_config() == nil

      Mail.put_test_source(:settings)
      assert Mail.source() == :settings
      assert Mail.configured?()
      # Sent under it, an email still goes through the tests' adapter.
      assert Mail.mailer_config()[:adapter] == Swoosh.Adapters.Test

      Mail.put_test_source(:env)
      assert Mail.source() == :env
      assert Mail.configured?()
    end
  end

  describe "the test seam" do
    test "reaches the processes that have the test among their callers" do
      Mail.put_test_source(:none)

      assert Task.async(fn -> Mail.source() end) |> Task.await() == :none

      # A task of a task: both are among its callers.
      nested = Task.async(fn -> Task.async(fn -> Mail.source() end) |> Task.await() end)
      assert Task.await(nested) == :none
    end

    test "a caller's own setting is nearer than the test's" do
      Mail.put_test_source(:none)

      task =
        Task.async(fn ->
          Mail.put_test_source(:settings)
          Task.async(fn -> Mail.source() end) |> Task.await()
        end)

      assert Task.await(task) == :settings
    end

    test "leaves every other process as it is" do
      Mail.put_test_source(:none)
      parent = self()

      spawn(fn -> send(parent, {:source, Mail.source()}) end)
      assert_receive {:source, :env}
    end

    # Tests that set different sources run at once, each seeing its own.
    for {source, n} <- Enum.with_index([:none, :settings, :env, :none, :settings, :env]) do
      test "holds #{source} while other tests set theirs (#{n})" do
        Mail.put_test_source(unquote(source))

        for _ <- 1..20 do
          assert Task.async(fn -> Mail.source() end) |> Task.await() == unquote(source)
          Process.sleep(1)
        end
      end
    end
  end
end

defmodule Apiary.MailBootTest do
  # Not async: raises the log level for every process.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Apiary.Mail

  describe "boot/0" do
    # The suite logs from :warning up; these tests from :info.
    setup do
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)
    end

    test "says once, at info, that no mail is set" do
      Mail.put_test_source(:none)
      log = capture_log([level: :info], fn -> assert Mail.boot() == :ok end)

      assert log =~
               "No mail is set: invitations and password links are copied by hand. " <>
                 "Set mail in Instance settings › Mail."

      assert length(String.split(log, "No mail is set")) == 2
    end

    test "says nothing when mail is set" do
      log = capture_log([level: :info], fn -> assert Mail.boot() == :ok end)
      refute log =~ "No mail is set"
    end
  end
end
