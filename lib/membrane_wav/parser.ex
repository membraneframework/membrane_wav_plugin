defmodule Membrane.WAV.Parser do
  @moduledoc """
  Element responsible for parsing WAV files.

  It requires WAV file in uncompressed, PCM format on the input (otherwise error is raised) and
  provides raw audio on the output. WAV header is parsed to extract metadata for creating caps.
  Then it is dropped and only samples are sent to the next element.

  The element has one option - `frames_per_buffer`. User can specify number of frames sent in one
  buffer when demand unit on the output is `:buffers`. One frame contains `bits per sample` x
  `number of channels` bits.

  ## WAV Header

  ```
     0                   4                   8                   12                  16
     _________________________________________________________________________________
  0  |                   |                   |                   |                   |
     |      "RIFF"       |    file length    |      "WAVE"       |       "fmt "      |
     |                   |                   |                   |                   |
     |___________________|___________________|___________________|___________________|
  16 |                   |         |         |                   |                   |
     |   format chunk    | format  |number of|      sample       | data transmission |
     |      length       |(1 - PCM)|channels |       rate        |       rate        |
     |___________________|_________|_________|___________________|___________________|
  32 |  block  |  bits   |                   |                   |                   |
     |  align  |  per    |      "fact"       |     fact chunk    |    samples per    |
     |  unit   | sample  |                   |       length      |      channel      |
     |_________|_________|___________________|___________________|___________________|
  48 |                   |                   |                                       |
     |      "data"       |    data length    |                 DATA                  |
     |                   |     in bytes      |                                       |
     |___________________|___________________|_______________________________________|
  ```
  Header may contain additional bytes between `bits per sample` and `"fact"` in case of `format`
  different from 1 (1 represents PCM / uncompressed format). Length of block from `format` until
  `"fact"` is present in `format chunk length` (it is 16 for PCM).

  Blocks from byte 36 to 48 are optional. There can be additional bytes after `samples per
  channel` if `fact chunk length` contains number bigger than 4.

  ## Parsing

  Stages of parsing:
  - `:init` - Parser waits for the first 22 bytes. After getting them, it parses these bytes
    to ensure that it is a WAV file. Parser knows `format chunk length` and `format`, so it
    is able to raise an error in case of different `format` than 1 (PCM) or different
    length than 16 (for PCM). After parsing, the stage is set to `:format`.
  - `:format` - Parser waits for the next 22 bytes - `fmt` chunk (bytes 20 - 35) without
    `format` and either `"fact"` and `fact chunk length` or `"data"` and `data length in bytes`.
    Then it parses it and create `Membrane.Caps.Audio.Raw` struct with audio format to send it
    as caps to the next element. Stage is set to `:fact` or `:data` depending on last 8 bytes.
  - `:fact` - Parser waits for `8 + fact chunk length` bytes. It  parses them only to check if
    the header is correct, but does not use that data in any way. After parsing, the stage is
    set to `:data`.
  - `:data` - header is already fully parsed. All new data from the input is sent to the output.

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
    caps: :any

  @impl true
  def handle_init(options) do
    state =
      options
      |> Map.from_struct()
      |> Map.put(:stage, :init)

    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(_context, state) do
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
  def handle_process(:input, buffer, _context, %{stage: :data} = state) do
    {{:ok, buffer: {:output, buffer}}, state}
  end

  def handle_process(
        :input,
        %Buffer{payload: payload} = _buffer,
        _context,
        %{stage: :init} = state
      ) do
    <<
      "RIFF",
      _file_size::32-little,
      "WAVE",
      "fmt ",
      format_chunk_size::32-little,
      format::16-little
    >> = payload

    check_format(format, format_chunk_size)

    demand = {:input, @format_stage_size}
    state = %{state | stage: :format}

    {{:ok, demand: demand}, state}
  end

  def handle_process(
        :input,
        %Buffer{payload: payload} = _buffer,
        _context,
        %{stage: :format} = state
      ) do
    <<
      channels::16-little,
      sample_rate::32-little,
      _data_transmission_rate::32,
      _block_alignment_unit::16,
      bits_per_sample::16-little,
      next_chunk_type::4-bytes,
      next_chunk_size::32-little
    >> = payload

    caps = %Caps{
      channels: channels,
      sample_rate: sample_rate,
      format: Format.from_tuple({:s, bits_per_sample, :le})
    }

    state = Map.merge(state, %{caps: caps})

    case next_chunk_type do
      "fact" ->
        state = %{state | stage: :fact}
        demand = {:input, @fact_stage_base_size + next_chunk_size}

        {{:ok, caps: {:output, caps}, demand: demand}, state}

      "data" ->
        state = %{state | stage: :data}

        {{:ok, caps: {:output, caps}, redemand: :output}, state}
    end
  end

  def handle_process(
        :input,
        %Buffer{payload: payload} = _buffer,
        _context,
        %{stage: :fact} = state
      ) do
    fact_chunk_size = 8 * (byte_size(payload) - @fact_stage_base_size)

    <<
      _fact_chunk::size(fact_chunk_size),
      "data",
      _data_length::32
    >> = payload

    state = %{state | stage: :data}

    {{:ok, redemand: :output}, state}
  end

  defp check_format(format, format_chunk_size) do
    cond do
      format != 1 ->
        raise(
          RuntimeError,
          "formats different than PCM are not supported; expected 1, given #{format}; format chunk size: #{format_chunk_size}"
        )

      format_chunk_size != @pcm_format_size ->
        raise(
          RuntimeError,
          "format chunk size different than supported; expected 16, given #{format_chunk_size}"
        )

      true ->
        :ok
    end
  end
end
