import Config

# Logger level from LOG_LEVEL env (default warn). At warn/error the app
# must not log per request. `:logger` is configured at runtime in the
# Application supervisor so the env var is honored; this config sets a
# sane default and the build-time env.
config :logger, level: :warn

import Config
