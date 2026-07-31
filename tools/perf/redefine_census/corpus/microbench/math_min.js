let sum = 0;
for (let i = 0; i < 60000; i++) sum += Math.min(i, 500);
print(sum);
