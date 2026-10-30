import sys, datetime, collections
from zoneinfo import ZoneInfo
f=lambda z,t: 'nil' if t=='nil' else datetime.datetime.fromtimestamp(int(t),ZoneInfo(z)).strftime('%Y-%m-%d %a %H:%M:%S')
a=[l.rstrip('\n').split('\t') for l in open(sys.argv[1])]
b=[l.rstrip('\n').split('\t') for l in open(sys.argv[2])]
show=int(sys.argv[3]) if len(sys.argv)>3 else 0
d=collections.Counter(); n=0
for x,y in zip(a,b):
    assert x[:4]==y[:4]
    if x[4]!=y[4]:
        d[(x[1],x[3])]+=1; n+=1
        if show and n<=show:
            print(x[0],x[1],x[3],'start',f(x[0],x[2])); print('   main  ',[f(x[0],t) for t in x[4].split(',')]); print('   branch',[f(x[0],t) for t in y[4].split(',')])
print('rows',len(a),'differ',n,'combos',len(d))
for k,v in sorted(d.items()): print(v,*k)
