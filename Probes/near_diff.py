import sys, collections, datetime
from zoneinfo import ZoneInfo
a=[l.rstrip('\n').split('\t') for l in open(sys.argv[1])]
b=[l.rstrip('\n').split('\t') for l in open(sys.argv[2])]
g=collections.Counter(); ex=collections.defaultdict(list)
def f(z,t):
    if t=='nil': return 'nil'
    x=float(t); d=datetime.datetime.fromtimestamp(x,ZoneInfo(z)); return d.strftime('%Y-%m-%d %H:%M:%S')+('.%d'%round((x%1)*10) if x%1 else '')
for x,y in zip(a,b):
    assert x[:7]==y[:7]
    if x[7]!=y[7]:
        comps=' '.join(p.split(':')[0] for p in x[3].split(' ') if ':' in p)
        k=(x[1],x[5],x[6],comps); g[k]+=1
        if len(ex[k])<2: ex[k].append(f"{x[2]} {x[3]} start={f(x[2],x[4])} main={f(x[2],x[7])} branch={f(x[2],y[7])}")
print('total', len(a), 'differ', sum(g.values()))
for k,n in g.most_common(40):
    print(n,*k)
    for e in ex[k]: print('   ',e)
