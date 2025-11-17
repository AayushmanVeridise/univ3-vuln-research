import math 

class PoolConfig: 

    def __init__(self, initial, upper_bound, lower_bound): 
        self.token0_initial = initial
        self.token0_upper_bound = upper_bound
        self.token0_lower_bound = lower_bound

        self.token1_initial = 1

    def set_prices(self):
        self.initial_price = math.sqrt(self.initial / self.token1_initial)
        self.upper_price_bound = math.sqrt(self.token0_upper_bound / self.token1_initial)
        self.lower_price_bound = math.sqrt(self.token0_lower_bound / self.token1_initial)

        return [self.initial_price, self.upper_price_bound, self.lower_price_bound]

    def set_price_to_sqrtp(self): 
        q96 = 2**96
        self.initial_price_sqrtp = int(math.sqrt(self.initial_price) * q96)
        self.upper_price_sqrtp = int(math.sqrt(self.upper_price_bound) * q96)
        self.lower_price_sqrtp = int(math.sqrt(self.lower_price_bound) * q96)

        return [self.initial_price_sqrtp, self.upper_price_sqrtp, self.lower_price_sqrtp]

    def set_price_ticks(self):
        self.initial_tick = math.floor(math.log(self.initial_price, 1.0001))
        self.upper_tick = math.floor(math.log(self.upper_price_bound, 1.0001))
        self.lower_tick = math.floor(math.log(self.lower_price_bound, 1.0001))

        return [self.initial_tick, self.upper_tick, self.lower_tick]

    def calculate_liqudiry(self): 
        pass        