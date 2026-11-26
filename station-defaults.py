"""Adapt a freshly created weewx.conf to running in a container."""
import sys

import weecfg
from weeutil.weeutil import option_as_list

path = sys.argv[1]
_, config = weecfg.read_config(path)

config['Logging'] = {'root': {'handlers': ['console']}}
config.comments['Logging'] = ['', '# Log to the container output; there is no syslog.']

# StdPrint writes every LOOP packet and archive record to stdout, which would
# flood the container log.
services = config['Engine']['Services']
report = option_as_list(services['report_services'])
services['report_services'] = [s for s in report if s != 'weewx.engine.StdPrint']

weecfg.save(config, path)
