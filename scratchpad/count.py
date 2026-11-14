import re
s=open('f2-followup-run-2026-10-30.log').read()
nums=re.findall(r'Executed (\d+) tests, with (\d+) failures', s)
tot=sum(int(a) for a,b in nums)
fail=sum(int(b) for a,b in nums)
print('sum executed lines:', len(nums))
print('total executed (sum):', tot)
print('total failures (sum):', fail)
