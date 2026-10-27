{
  "Role": "__MEDIACONVERT_ROLE_ARN__",
  "Queue": "arn:aws:mediaconvert:__REGION__:__ACCOUNT_ID__:queues/Default",
  "UserMetadata": {
    "project": "stt-poc"
  },
  "Settings": {
    "TimecodeConfig": {
      "Source": "ZEROBASED"
    },
    "Inputs": [
      {
        "FileInput": "s3://__BUCKET__/input/EXAMPLE.mp3",
        "AudioSelectors": {
          "Audio Selector 1": {
            "DefaultSelection": "DEFAULT"
          }
        }
      }
    ],
    "OutputGroups": [
      {
        "Name": "Audio FLAC + AAC",
        "OutputGroupSettings": {
          "Type": "FILE_GROUP_SETTINGS",
          "FileGroupSettings": {
            "Destination": "s3://__BUCKET__/output/"
          }
        },
        "Outputs": [
          {
            "NameModifier": "_flac48k_stereo",
            "ContainerSettings": {
              "Container": "RAW"
            },
            "AudioDescriptions": [
              {
                "AudioSourceName": "Audio Selector 1",
                "CodecSettings": {
                  "Codec": "FLAC",
                  "FlacSettings": {
                    "BitDepth": 16,
                    "Channels": 2,
                    "SampleRate": 48000
                  }
                }
              }
            ]
          },
          {
            "NameModifier": "_playback",
            "ContainerSettings": {
              "Container": "MP4",
              "Mp4Settings": {
                "CslgAtom": "INCLUDE",
                "FreeSpaceBox": "EXCLUDE",
                "MoovPlacement": "PROGRESSIVE_DOWNLOAD"
              }
            },
            "AudioDescriptions": [
              {
                "AudioSourceName": "Audio Selector 1",
                "CodecSettings": {
                  "Codec": "AAC",
                  "AacSettings": {
                    "Bitrate": 128000,
                    "CodingMode": "CODING_MODE_2_0",
                    "SampleRate": 48000,
                    "CodecProfile": "LC",
                    "RateControlMode": "CBR",
                    "RawFormat": "NONE",
                    "Specification": "MPEG4"
                  }
                }
              }
            ]
          }
        ]
      }
    ]
  }
}
