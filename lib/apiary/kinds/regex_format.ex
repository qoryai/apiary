defmodule Apiary.Kinds.RegexFormat do
  @moduledoc """
  RegexFormat checks the `"regex"` format for a check run under `Apiary.Kinds.Budget`, in
  place of JSV's default format validator, which compiles the value each time a
  `"format": "regex"` applies to it. A compile is work in PCRE that the runtime barely
  counts in reductions, so a schema that applies the format to one value many times, or to
  many long values, could make work that the budget does not see.

  So, for each value, the first time it is checked, it charges the process reductions in
  proportion to the value's bytes (with `:erlang.bump_reductions/1`) and compiles it with
  `Regex.compile/1`; the result is kept in the process dictionary by value, so each
  distinct value is compiled once in the process. The verdict is the one JSV's default
  gives: a value is valid exactly when `Regex.compile/1` takes it.

  The process dictionary is not cleared: use it in a process that ends after the check,
  such as the one `Apiary.Kinds.Budget.run/2` starts. Every other format goes to JSV's
  default modules (`formats/0`).
  """

  @behaviour JSV.FormatValidator

  # The reductions charged for a compile, for each byte of the value, counting
  # @fixed_bytes more for the cost of any compile. Measured on ordinary valid patterns
  # (alternations of ordinary patterns, literals, character classes) of 0 B to 19 KB:
  # Regex.compile takes at most 37 ns a byte, and at least 290 ns for any pattern, while
  # JSV's ordinary work counts at most 235 reductions a microsecond. At that rate a byte
  # of compile is worth at most 9 reductions and any compile at least 70; the charge,
  # 10 * (bytes + 8), is above both.
  @reductions_per_byte 10
  @fixed_bytes 8
  @charge_part 1000

  @key {__MODULE__, :compiled}

  @doc """
  formats/0 is the list for JSV's `formats:` build option: this module, then JSV's
  default modules for every other format.
  """
  @spec formats() :: [module]
  def formats, do: [__MODULE__ | JSV.default_format_validator_modules()]

  @impl true
  def supported_formats, do: ["regex"]

  @impl true
  def applies_to_type?("regex", data), do: is_binary(data)

  @impl true
  def validate_cast("regex", data) do
    compiled = Process.get(@key, %{})

    case compiled do
      %{^data => result} ->
        result

      _ ->
        charge(@reductions_per_byte * (byte_size(data) + @fixed_bytes))
        result = Regex.compile(data)
        Process.put(@key, Map.put(compiled, data, result))
        result
    end
  end

  # One call of :erlang.bump_reductions/1 counts at most what is left of the process's
  # time slice, so it is called, in parts of at most @charge_part, until the process's
  # count of reductions has grown by the charge.
  defp charge(reductions), do: charge_until(own_reductions() + reductions)

  defp charge_until(target) do
    left = target - own_reductions()

    if left > 0 do
      :erlang.bump_reductions(min(left, @charge_part))
      charge_until(target)
    end
  end

  defp own_reductions do
    {:reductions, reductions} = Process.info(self(), :reductions)
    reductions
  end
end
