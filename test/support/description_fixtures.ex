defmodule Apiary.DescriptionFixtures do
  @moduledoc """
  Descriptions of integrations for the tests: synthetic, in the shape of the integrations
  contract, and a `qory-github` description in the shape of the contract's `github.json`,
  as the tests' made-up release 0.1.0 of it carries it.
  """

  @doc """
  A `qory-github` description in the shape of the contract's `github.json`, at the tests'
  version 0.1.0, with `overrides` merged at the top: `app_id` and `api_url` are its plain
  settings, and `private_key` its secret.
  """
  def github_description(overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "name" => "github",
        "title" => "GitHub",
        "description" => "Mints GitHub App installation tokens.",
        "domains" => ["software"],
        "program_version" => "0.1.0",
        "settings" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "app_id" => %{
              "title" => "App id",
              "type" => ["integer", "string"],
              "pattern" => "^[A-Za-z0-9.]{1,64}$"
            },
            "api_url" => %{"title" => "API", "type" => "string", "pattern" => "^https://"},
            "private_key" => %{
              "title" => "Private key",
              "type" => "string",
              "writeOnly" => true
            },
            "private_key_file" => %{"title" => "Private key file", "type" => "string"}
          }
        },
        "roles" => %{
          "credential" => %{
            "argument" => "[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}",
            "hosts" => ["github.com", "api.github.com"]
          }
        }
      },
      overrides
    )
  end

  @doc "A description with a credential role and a role Qory Apiary does not know, `acme_role`."
  def tracker_description(overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "name" => "acme-tracker",
        "title" => "Acme tracker",
        "program_version" => "0.3.0",
        "settings" => %{
          "type" => "object",
          "properties" => %{
            "url" => %{"title" => "Tracker", "type" => "string"},
            "api_key" => %{"title" => "API key", "type" => "string", "writeOnly" => true},
            "api_key_file" => %{"title" => "API key file", "type" => "string"}
          }
        },
        "roles" => %{
          "credential" => %{
            "argument" => "[A-Z]+",
            "hosts" => ["tracker.example.com"]
          },
          "acme_role" => %{"events" => ["issue.opened"]}
        }
      },
      overrides
    )
  end

  @doc "`description` encoded as a release would publish it."
  def encode(description), do: Jason.encode!(description)

  @doc "checksums.txt for the bytes of `description`, as a release publishes it."
  def checksums(bytes) do
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    "#{String.duplicate("0", 64)}  qory-github_0.1.0_linux_amd64.tar.gz\n#{hash}  description.json\n"
  end
end
