# Membrane WAV Plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_wav_plugin.svg)](https://hex.pm/packages/membrane_wav_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_wav_plugin)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_wav_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_wav_plugin)

Plugin providing elements handling audio in WAV file format.

It is part of [Membrane Multimedia Framework](https://membraneframework.org).

## Installation

The package can be installed by adding `membrane_wav_plugin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
	{:membrane_wav_plugin, "~> 0.9.0"}
  ]
end
```

## Parser

The Parser requires a WAV file on the input and provides a raw audio in uncompressed, PCM format on
the output.

Parsing steps:

- Reading WAV header
- Extracting audio metadata and sending it through a pad to the next element
- Sending only audio samples to the next elements

It can parse only uncompressed audio.

## Serializer

The Serializer adds WAV header to the raw audio in uncompressed, PCM format.

### Warning

The Serializer creates header with invalid blocks which depend on the file size. You can bypass this
using `Membrane.File.Sink` to save the file or fixing the header afterwards with `Membrane.WAV.Postprocessing`
if you need to use any other sink.

## Sample usage

```elixir
defmodule Mixing.Pipeline do
  use Membrane.Pipeline

  @impl true
  def handle_init(_) do
    children = [
      file_src: %Membrane.File.Source{location: "/tmp/input.wav"},
      parser: Membrane.WAV.Parser,
      converter: %Membrane.FFmpeg.SWResample.Converter{
        input_stream_format: %Membrane.RawAudio{channels: 1, sample_rate: 16_000, sample_format: :s16le},
        output_stream_format: %Membrane.RawAudio{channels: 2, sample_rate: 48_000, sample_format: :s16le}
      },
      serializer: Membrane.WAV.Serializer,
      file_sink: %Membrane.File.Sink{location: "/tmp/output.wav"},
    ]

    links = [
      link(:file_src)
      |> to(:parser)
      |> to(:converter)
      |> to(:serializer)
      |> to(:file_sink)
    ]

    {{:ok, spec: %ParentSpec{children: children, links: links}}, %{}}
  end
end
```

## Copyright and License

Copyright 2021, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane)

Licensed under the [Apache License, Version 2.0](LICENSE)
