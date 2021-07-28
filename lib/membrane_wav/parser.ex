defmodule Membrane.WAV.Parser do
  @moduledoc """
    Element responsible for parsing WAV files.

    It parses only PCM / uncompressed format. In case of different format, error is raised.
    ```
                                        WAV Header
     0                   4                   8                   12                  16
     _________________________________________________________________________________
  0  |                   |                   |                   |                   |
     |      "RIFF"       |    file length    |      "WAVE"       |       "fmt "      |
     |                   |                   |                   |                   |
     |___________________|___________________|___________________|___________________|
  16 |                   |         |         |                   |                   |
     |   format block    | format  |number of|      sample       | data transmission |
     |      length       |(1 - PCM)|channels |       rate        |       rate        |
     |___________________|_________|_________|___________________|___________________|
  32 |  block  |  bits   |                   |                   |                   |
     |  align  |  per    |      "fact"       |     fact block    |    samples per    |
     |  unit   | sample  |                   |       length      |      channel      |
     |_________|_________|___________________|___________________|___________________|
  48 |                   |                   |                                       |
     |      "data"       |    data length    |                 DATA                  |
     |                   |     in bytes      |                                       |
     |___________________|___________________|_______________________________________|
    ```
    Header may contain additional bytes between `bits per sample` and `"fact"` in case of `format`
    different than 1 (1 represents PCM / uncompressed format). Length of block from `format` until
    `"fact"` is present in `format block length` (it is 16 for PCM).

    Blocks from byte 36 to 48 are optional. There can be additional bytes after `samples per
    channel` if `fact block length` contains number bigger than 4.

    Stages of parsing:
    - `:init` - Parser waits for the first 22 bytes. After getting them, it parses these bytes
      to ensure that it is a WAV file. Parser knows `format block length` and `format`, so it
      is able to raise an error in case of different `format` than 1 (PCM) or different
      length than 16 (for PCM). After parsing, stage is set to `:format`.
    - `:format` - Parser waits for the next 22 bytes - `fmt` subchunk (bytes 20 - 35) without
      `format` and either `"fact"` and `fact block length` or `"data"` and `data length in bytes`.
      Then it parses it and create `Membrane.Caps.Audio.Raw` struct with audio format to send it
      as caps to the next element. Stage is set to `:fact` or `:data` depending on last 8 bytes.
    - `:fact` - Parser waits for `8 + fact block length` bytes. It  parses them only to check if
      the header is correct, but does not use that data in any way. After parsing, stage is set to
      `:data`.
    - `:data` - header is already fully parsed. All new data from input is sent to the output.
  """

  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.Caps.Audio.Raw, as: Caps
  alias Membrane.Caps.Audio.Raw.Format

  require Membrane.Logger

  @pcm_format_size 16

  @init_stage_size 22
  @format_stage_size 22
  @fact_stage_base_size 8

  def_options frames_per_buffer: [
                type: :integer,
                spec: pos_integer(),
                description: """
                Assumed number of raw audio frames in each buffer.
                Used when converting demand from buffers into bytes.
                """,
                default: 2048
              ]

  def_output_pad :output,
    mode: :pull,
    availability: :always,
    caps: Caps

  def_input_pad :input,
    mode: :pull,
    availability: :always,
    demand_unit: :bytes,
    caps: Caps

  @impl true
  def handle_init(state) do
    state = Map.merge(state, %{stage: :init, queue: <<>>})

    {:ok, state}
  end

  @impl true
  def handle_start_of_stream(:input, _context, state) do
    demand = {:input, @init_stage_size}

    {{:ok, demand: demand}, state}
  end

  @impl true
  def handle_demand(:output, size, :bytes, _context, %{stage: :data} = state) do
    {{:ok, demand: {:input, size}}, state}
  end

  def handle_demand(
        :output,
        buffers_count,
        :buffers,
        _context,
        %{stage: :data, frames_per_buffer: frames, caps: caps} = state
      ) do
    size = buffers_count * Caps.frames_to_bytes(frames, caps)

    {{:ok, demand: {:input, size}}, state}
  end

  def handle_demand(:output, _size, _unit, _context, state) do
    {:ok, state}
  end

  @impl true
  def handle_event(_pad, event, _context, state) do
    Membrane.Logger.debug("Received event #{inspect(event)}")

    {:ok, state}
  end

  @impl true
  def handle_process(:input, buffer, context, %{stage: :data} = state) do
    if context.pads.input.demand == 0 do
      {{:ok, buffer: {:output, buffer}, redemand: :output}, state}
    else
      {{:ok, buffer: {:output, buffer}}, state}
    end
  end

  def handle_process(:input, %Buffer{payload: payload} = _buffer, context, state)
      when byte_size(payload) < context.pads.input.demand do
    demand_fun = &(&1 - byte_size(payload))
    state = Map.update(state, :queue, payload, &(&1 <> payload))

    {{:ok, demand: {:input, demand_fun}}, state}
  end

  def handle_process(
        :input,
        %Buffer{payload: payload} = _buffer,
        _context,
        %{stage: :init, queue: queue} = state
      ) do
    "RIFF" <>
      <<_file_size::binary-size(4)>> <>
      "WAVE" <>
      "fmt " <>
      <<format_size::binary-size(4)>> <>
      <<format::binary-size(2)>> = queue <> payload

    check_format(format, format_size)

    demand = {:input, @format_stage_size}
    state = %{state | stage: :format, queue: <<>>}

    {{:ok, demand: demand}, state}
  end

  def handle_process(
        :input,
        %Buffer{payload: payload} = _buffer,
        _context,
        %{stage: :format, queue: queue} = state
      ) do
    <<channels::binary-size(2)>> <>
      <<sample_rate::binary-size(4)>> <>
      <<_data_transmission_rate::binary-size(4)>> <>
      <<_block_alignment_unit::binary-size(2)>> <>
      <<bits_per_sample::binary-size(2)>> <>
      <<next_header_element::binary-size(8)>> = queue <> payload

    caps = %Caps{
      channels: binary_to_number(channels),
      sample_rate: binary_to_number(sample_rate),
      format: Format.from_tuple({:s, binary_to_number(bits_per_sample), :le})
    }

    state = Map.merge(state, %{caps: caps, queue: <<>>})

    case next_header_element do
      "fact" <> <<fact_length::binary-size(4)>> ->
        state = %{state | stage: :fact}
        demand = {:input, @fact_stage_base_size + binary_to_number(fact_length)}

        {{:ok, caps: {:output, caps}, demand: demand}, state}

      "data" <> <<_data_length::binary-size(4)>> ->
        state = %{state | stage: :data}

        {{:ok, caps: {:output, caps}, redemand: :output}, state}
    end
  end

  def handle_process(
        :input,
        %Buffer{payload: payload} = _buffer,
        _context,
        %{stage: :fact, queue: queue} = state
      ) do
    fact_block_size = byte_size(payload) - @fact_stage_base_size

    <<_fact_block::binary-size(fact_block_size)>> <>
      "data" <>
      <<_data_length::binary-size(4)>> = queue <> payload

    state = %{state | stage: :data, queue: <<>>}

    {{:ok, redemand: :output}, state}
  end

  defp check_format(binary_format, binary_format_size) do
    format = binary_to_number(binary_format)
    format_size = binary_to_number(binary_format_size)

    cond do
      format != 1 ->
        raise(
          RuntimeError,
          "formats different than PCM are not supported; expected 1, given #{format}; format subchunk size: #{format_size}"
        )

      format_size != @pcm_format_size ->
        raise(
          RuntimeError,
          "format subchunk size different than supported; expected 16, given #{format_size}"
        )

      true ->
        :ok
    end
  end

  defp binary_to_number(binary) do
    size = 8 * byte_size(binary)
    <<number::unsigned-little-integer-size(size)>> = binary
    number
  end
end
