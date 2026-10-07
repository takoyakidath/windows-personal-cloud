"""Entry point: python -m bot [path/to/controller.json]"""

import sys

from bot.app import run
from core.config import DEFAULT_PATH, ConfigError, load_config
from core.logs import setup_logging

if __name__ == "__main__":
    try:
        config = load_config(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PATH)
    except ConfigError as e:
        sys.exit(f"config error: {e}")
    setup_logging(config.log_dir)
    run(config)
