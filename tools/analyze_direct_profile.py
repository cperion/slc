"""Join perf flat PCs to copied stencil regions, excluding setup/compilation."""
import bisect
import collections
import csv
import pathlib
import re
import sys

for prefix in sys.argv[1:]:
    log = pathlib.Path(prefix + '.log').read_text()
    match = re.search(r'begin=([\d.]+) end=([\d.]+)', log)
    begin, end = map(float, match.groups())
    path = pathlib.Path(prefix + '-regions.csv')
    regions = []
    if path.exists():
        for row in csv.DictReader(path.open()):
            row['start'], row['end'] = int(row['start'], 16), int(row['end'], 16)
            regions.append(row)
    regions.sort(key=lambda r: r['start'])
    starts = [r['start'] for r in regions]
    ops, functions, detail = collections.Counter(), collections.Counter(), collections.Counter()
    total = 0
    for line in pathlib.Path(prefix + '-samples.txt').read_text().splitlines():
        fields = line.split(None, 2)
        if len(fields) != 3:
            continue
        timestamp = float(fields[0].rstrip(':'))
        if not begin <= timestamp <= end:
            continue
        ip = int(fields[1], 16)
        i = bisect.bisect_right(starts, ip) - 1
        total += 1
        if i >= 0 and ip < regions[i]['end']:
            r = regions[i]
            ops[r['stencil']] += 1
            functions[r['function']] += 1
            suffix = r['native'] or r['imm']
            detail[r['stencil'] + (':' + suffix if suffix else '')] += 1
        elif i >= 0 and i+1 < len(regions) and regions[i+1]['start']-regions[i]['end'] < 16:
            ops['alignment'] += 1
        else:
            symbol = fields[2]
            ops[symbol] += 1
    print('\n' + prefix + ': ' + str(total) + ' execution-window samples')
    if 'lost' in log:
        print('WARNING: capture reported lost events; do not treat as clean evidence')
    for title, counts in [('PC categories', ops), ('VM functions', functions), ('VM detail', detail)]:
        print(title)
        for name, count in counts.most_common(18):
            print(f'{count/total*100:6.2f}% {count:6d} {name}')
