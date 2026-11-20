defmodule Apiary.Adapters.ChangeReportTest do
  # The reply and the failure of a change request, read as the integrations contract has
  # them: every fixture of `changes-submitted/`, `changes-failed/change-request-*`, `invalid/`
  # and `refused-by-control-plane/` vendored from the commit in `.integration-contract-ref`,
  # and each rule that a schema cannot state.
  use ExUnit.Case, async: true

  alias Apiary.Adapters.{ChangeReport, Wire}

  @fixtures Path.expand("../../fixtures/integration-contract/adapter", __DIR__)

  defp fixtures(pattern) do
    @fixtures
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, @fixtures))
    |> Enum.sort()
  end

  defp raw(path), do: @fixtures |> Path.join(path) |> File.read!()
  defp json(path), do: path |> raw() |> Jason.decode!()

  defp reply(changes),
    do: Map.merge(json("changes-submitted/pull-request-created.json"), changes)

  describe "a reply" do
    test "every body of changes-submitted/ is read, with the members the entry stores" do
      paths = fixtures("changes-submitted/*.json")
      assert length(paths) == 6

      for path <- paths do
        body = json(path)

        assert {:ok, report} = ChangeReport.submitted(body), path
        assert report.change_request_id == body["change_request_id"]
        assert report.collection == body["target"]["collection"]
        assert report.reply == Map.take(body, ~w(action address data))
        assert {:ok, report.time} == Wire.time(body["time"])
      end
    end

    test "every invalid body is refused" do
      paths = fixtures("invalid/changes-submitted-*.json")
      assert length(paths) == 10

      for path <- paths, do: assert(ChangeReport.submitted(json(path)) == :error, path)
    end

    test "a body that the control plane refuses is refused: another host, a member twice" do
      assert ChangeReport.submitted(
               json("refused-by-control-plane/changes-submitted-address-other-host.json")
             ) ==
               :error

      assert Wire.decode(
               raw("refused-by-control-plane/changes-submitted-data-repeated-member.json")
             ) ==
               :error
    end

    test "ignores a member that the schema does not define" do
      assert {:ok, _report} = ChangeReport.submitted(reply(%{"extra" => 1}))
      assert ChangeReport.submitted(reply(%{"must_understand" => ["/extra"]})) == :error
    end

    test "is refused when the data is over 786432 bytes serialized" do
      assert ChangeReport.submitted(
               reply(%{"data" => %{"text" => String.duplicate("a", 786_433)}})
             ) ==
               :error
    end

    test "has an address.url on the system of the target, in lower case, with no port, query or fragment" do
      good = "https://code.example.com/acme/shop/pull/34"
      assert {:ok, _} = ChangeReport.submitted(reply(%{"address" => %{"url" => good}}))

      for url <- [
            "https://Code.example.com/acme/shop/pull/34",
            "https://code.example.com:8443/acme/shop/pull/34",
            "https://code.example.com/acme/shop/pull/34?x=1",
            "https://code.example.com/acme/shop/pull/34#top",
            "https://code.example.com",
            "https://code.example.com/",
            "https://code%2eexample.com/acme/shop/pull/34",
            "https://[::1]/acme/shop/pull/34",
            "https://sub.code.example.com/acme/shop/pull/34"
          ] do
        assert ChangeReport.submitted(reply(%{"address" => %{"url" => url}})) == :error, url
      end
    end

    test "has only the form of an address.url when the target has no address" do
      body = %{
        "target" => %{"collection" => "SUPPORT"},
        "address" => %{"url" => "https://anything.example.org/cases/1"}
      }

      assert {:ok, _} = ChangeReport.submitted(reply(body))
    end

    test "is no body when it is no map" do
      assert ChangeReport.submitted(nil) == :error
    end
  end

  describe "a failure" do
    test "every body of changes-failed/change-request-* is read" do
      paths = fixtures("changes-failed/change-request-*.json")
      assert length(paths) == 11

      for path <- paths do
        body = json(path)
        assert {:ok, report} = ChangeReport.failed(body), path
        assert Atom.to_string(report.reason) == body["reason"]
        assert report.detail == body["detail"]
        assert report.collection == body["target"]["collection"]
      end
    end

    test "every invalid body of a change request is refused" do
      paths = fixtures("invalid/changes-failed-change-request-*.json")
      assert length(paths) == 11

      for path <- paths, do: assert(ChangeReport.failed(json(path)) == :error, path)
    end

    test "is no change request report for a report about a comment" do
      assert ChangeReport.failed(json("changes-failed/not-permitted.json")) == :error
    end

    test "is refused for the reason invalid, which an adapter never sends" do
      body = Map.put(json("changes-failed/change-request-refused.json"), "reason", "invalid")
      assert ChangeReport.failed(body) == :error
    end
  end
end
