defmodule Apiary.DescriptionFixtures do
  @moduledoc """
  Descriptions of integrations for the tests: synthetic, in the shape of the integrations
  contract, and the `qory-github` 0.1.0 description, as its release would publish it.
  """

  @doc "The decoded description of `qory-github` 0.1.0, with `overrides` merged at the top."
  def github_description(overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "name" => "github",
        "title" => "GitHub",
        "publisher" => %{"name" => "Qory", "url" => "https://qory.dev"},
        "description" => "Mints a GitHub App installation token for a run's repositories.",
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
              "writeOnly" => true,
              "x-secret-name" => "GITHUB_APP_PRIVATE_KEY"
            },
            "private_key_file" => %{"title" => "Private key file", "type" => "string"}
          }
        },
        "roles" => %{
          "credential" => %{
            "argument" => "[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}",
            "hosts" => ["github.com", "api.github.com"],
            "settings" => ["app_id", "api_url", "private_key"],
            "required" => ["app_id", "private_key"]
          }
        }
      },
      overrides
    )
  end

  @doc "A description with both ways, a credential role and a tool role with an MCP URL."
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
            "hosts" => ["tracker.example.com"],
            "settings" => ["url", "api_key"]
          },
          "tool" => %{
            "serves" => ["mcp.example.com"],
            "mcp" => "https://mcp.example.com/mcp",
            "placeholders" => ["TRACKER_MCP_KEY"],
            "settings" => ["url"]
          },
          "work_source" => %{"events" => ["issue.opened"]}
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
