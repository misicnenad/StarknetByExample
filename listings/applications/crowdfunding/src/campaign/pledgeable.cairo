// ANCHOR: component
use starknet::ContractAddress;

#[starknet::interface]
pub trait IPledgeable<TContractState> {
    fn add(ref self: TContractState, pledger: ContractAddress, amount: u256);
    fn get(self: @TContractState, pledger: ContractAddress) -> u256;
    fn get_pledger_count(self: @TContractState) -> u32;
    fn get_pledgers_as_arr(self: @TContractState) -> Array<ContractAddress>;
    fn get_total(self: @TContractState) -> u256;
    fn remove(ref self: TContractState, pledger: ContractAddress) -> u256;
}

#[starknet::component]
pub mod pledgeable_component {
    use core::traits::IndexView;
    use core::array::ArrayTrait;
    use starknet::{ContractAddress};
    use core::num::traits::Zero;
    use alexandria_storage::list::{List, ListTrait};

    #[storage]
    struct Storage {
        pledgers: List<ContractAddress>,
        pledger_to_amount: LegacyMap<ContractAddress, u256>,
        total_amount: u256,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {}

    mod Errors {
        pub const INCONSISTENT_STATE: felt252 = 'Non-indexed pledger found';
    }

    #[embeddable_as(Pledgeable)]
    pub impl PledgeableImpl<
        TContractState, +HasComponent<TContractState>
    > of super::IPledgeable<ComponentState<TContractState>> {
        fn add(ref self: ComponentState<TContractState>, pledger: ContractAddress, amount: u256) {
            let old_amount: u256 = self.pledger_to_amount.read(pledger);

            if old_amount == 0 {
                let mut pledgers = self.pledgers.read();
                pledgers.append(pledger).unwrap();
            }

            self.pledger_to_amount.write(pledger, old_amount + amount);
            self.total_amount.write(self.total_amount.read() + amount);
        }

        fn get(self: @ComponentState<TContractState>, pledger: ContractAddress) -> u256 {
            self.pledger_to_amount.read(pledger)
        }

        fn get_pledger_count(self: @ComponentState<TContractState>) -> u32 {
            self.pledgers.read().len()
        }

        fn get_pledgers_as_arr(self: @ComponentState<TContractState>) -> Array<ContractAddress> {
            let pledgers = self.pledgers.read();
            pledgers.array().unwrap()
        }

        fn get_total(self: @ComponentState<TContractState>) -> u256 {
            self.total_amount.read()
        }

        fn remove(ref self: ComponentState<TContractState>, pledger: ContractAddress) -> u256 {
            let amount: u256 = self.pledger_to_amount.read(pledger);

            // check if the pledge even exists
            if amount == 0 {
                return 0;
            }

            let mut pledgers = self.pledgers.read();
            assert(pledgers.len() != 0, Errors::INCONSISTENT_STATE);

            let first_pledger = match pledgers.pop_front() {
                Result::Ok(val) => val.unwrap(), // there was at least 1 list item
                Result::Err(errs) => panic(errs)
            };

            // if we popped a different pledger, we must use it to overwrite
            // the pledger we're trying to remove
            if first_pledger != pledger {
                assert(pledgers.len() != 0, Errors::INCONSISTENT_STATE);
                let mut index = pledgers.len() - 1;
                loop {
                    if pledgers.get(index).unwrap().unwrap() == pledger {
                        pledgers.set(index, first_pledger).unwrap();
                        break;
                    }
                    assert(index != 0, Errors::INCONSISTENT_STATE);
                    index -= 1;
                };
            }

            self.pledger_to_amount.write(pledger, 0);
            self.total_amount.write(self.total_amount.read() - amount);

            amount
        }
    }
}
// ANCHOR_END: component

#[cfg(test)]
mod tests {
    #[starknet::contract]
    mod MockContract {
        use super::super::pledgeable_component;

        component!(path: pledgeable_component, storage: pledges, event: PledgeableEvent);

        #[storage]
        struct Storage {
            #[substorage(v0)]
            pledges: pledgeable_component::Storage,
        }

        #[event]
        #[derive(Drop, starknet::Event)]
        enum Event {
            PledgeableEvent: pledgeable_component::Event
        }

        #[abi(embed_v0)]
        impl Pledgeable = pledgeable_component::Pledgeable<ContractState>;
    }

    use super::{pledgeable_component, IPledgeableDispatcher, IPledgeableDispatcherTrait};
    use super::pledgeable_component::{PledgeableImpl};
    use starknet::{ContractAddress, contract_address_const};
    use core::num::traits::Zero;

    type TestingState = pledgeable_component::ComponentState<MockContract::ContractState>;

    // You can derive even `Default` on this type alias
    impl TestingStateDefault of Default<TestingState> {
        fn default() -> TestingState {
            pledgeable_component::component_state_for_testing()
        }
    }

    #[test]
    fn test_add() {
        let mut pledgeable: TestingState = Default::default();
        let pledger_1 = contract_address_const::<'pledger_1'>();
        let pledger_2 = contract_address_const::<'pledger_2'>();

        assert_eq!(pledgeable.get_pledger_count(), 0);
        assert_eq!(pledgeable.get_total(), 0);
        assert_eq!(pledgeable.get(pledger_1), 0);
        assert_eq!(pledgeable.get(pledger_2), 0);

        // 1st pledge
        pledgeable.add(pledger_1, 1000);

        assert_eq!(pledgeable.get_pledger_count(), 1);
        assert_eq!(pledgeable.get_total(), 1000);
        assert_eq!(pledgeable.get(pledger_1), 1000);
        assert_eq!(pledgeable.get(pledger_2), 0);

        // 2nd pledge should be added onto 1st
        pledgeable.add(pledger_1, 1000);

        assert_eq!(pledgeable.get_pledger_count(), 1);
        assert_eq!(pledgeable.get_total(), 2000);
        assert_eq!(pledgeable.get(pledger_1), 2000);
        assert_eq!(pledgeable.get(pledger_2), 0);

        // different pledger stored separately
        pledgeable.add(pledger_2, 500);

        assert_eq!(pledgeable.get_pledger_count(), 2);
        assert_eq!(pledgeable.get_total(), 2500);
        assert_eq!(pledgeable.get(pledger_1), 2000);
        assert_eq!(pledgeable.get(pledger_2), 500);
    }

    #[test]
    fn test_remove() {
        let mut pledgeable: TestingState = Default::default();
        let pledger_1 = contract_address_const::<'pledger_1'>();
        let pledger_2 = contract_address_const::<'pledger_2'>();
        let pledger_3 = contract_address_const::<'pledger_3'>();

        pledgeable.add(pledger_1, 2000);
        pledgeable.add(pledger_2, 3000);
        // pledger_3 not added

        assert_eq!(pledgeable.get_pledger_count(), 2);
        assert_eq!(pledgeable.get_total(), 5000);
        assert_eq!(pledgeable.get(pledger_1), 2000);
        assert_eq!(pledgeable.get(pledger_2), 3000);
        assert_eq!(pledgeable.get(pledger_3), 0);

        let amount = pledgeable.remove(pledger_1);

        assert_eq!(amount, 2000);
        assert_eq!(pledgeable.get_pledger_count(), 1);
        assert_eq!(pledgeable.get_total(), 3000);
        assert_eq!(pledgeable.get(pledger_1), 0);
        assert_eq!(pledgeable.get(pledger_2), 3000);
        assert_eq!(pledgeable.get(pledger_3), 0);

        let amount = pledgeable.remove(pledger_2);

        assert_eq!(amount, 3000);
        assert_eq!(pledgeable.get_pledger_count(), 0);
        assert_eq!(pledgeable.get_total(), 0);
        assert_eq!(pledgeable.get(pledger_1), 0);
        assert_eq!(pledgeable.get(pledger_2), 0);
        assert_eq!(pledgeable.get(pledger_3), 0);

        // pledger_3 not added, so this should do nothing and return 0
        let amount = pledgeable.remove(pledger_3);

        assert_eq!(amount, 0);
        assert_eq!(pledgeable.get_pledger_count(), 0);
        assert_eq!(pledgeable.get_total(), 0);
        assert_eq!(pledgeable.get(pledger_1), 0);
        assert_eq!(pledgeable.get(pledger_2), 0);
        assert_eq!(pledgeable.get(pledger_3), 0);
    }

    #[test]
    fn test_remove_first_1000_pledgers() {
        let mut pledgeable: TestingState = Default::default();

        // set up 1000 pledgers
        let expected_pledger_count: u32 = 1000;
        let mut expected_total: u256 = 0; // actual value set up in the while loop

        let mut i: felt252 = expected_pledger_count.into();
        let first_pledger: ContractAddress = i.try_into().unwrap();
        let first_amount = 100000;
        pledgeable.add(first_pledger, first_amount);
        expected_total += first_amount;
        i -= 1;

        while i != 0 {
            let pledger: ContractAddress = i.try_into().unwrap();
            let amount: u256 = i.into() * 100;
            pledgeable.add(pledger, amount);
            expected_total += amount;
            i -= 1;
        };

        assert_eq!(pledgeable.get_total(), expected_total);
        assert_eq!(pledgeable.get_pledger_count(), expected_pledger_count);
        assert_eq!(pledgeable.get(first_pledger), first_amount);

        let removed_amount = pledgeable.remove(first_pledger);

        expected_total -= first_amount;

        assert_eq!(removed_amount, first_amount);
        assert_eq!(pledgeable.get_total(), expected_total);
        assert_eq!(pledgeable.get_pledger_count(), expected_pledger_count - 1);
        assert_eq!(pledgeable.get(first_pledger), 0);
    }

    #[test]
    fn test_remove_middle_1000_pledgers() {
        let mut pledgeable: TestingState = Default::default();

        // set up 1000 pledgers
        let expected_pledger_count: u32 = 1000;
        let mut expected_total: u256 = 0; // actual value set up in the while loop

        let mut middle_pledger: ContractAddress = Zero::zero();
        let mut middle_amount = 0;

        let mut i: felt252 = expected_pledger_count.into();
        while i != 0 {
            let pledger: ContractAddress = i.try_into().unwrap();
            let amount: u256 = i.into() * 100;
            pledgeable.add(pledger, amount);
            expected_total += amount;

            if i == 500 {
                middle_pledger = pledger;
                middle_amount = amount;
            }

            i -= 1;
        };

        assert_eq!(pledgeable.get_total(), expected_total);
        assert_eq!(pledgeable.get_pledger_count(), expected_pledger_count);
        assert_eq!(pledgeable.get(middle_pledger), middle_amount);

        let removed_amount = pledgeable.remove(middle_pledger);

        expected_total -= middle_amount;

        assert_eq!(removed_amount, middle_amount);
        assert_eq!(pledgeable.get_total(), expected_total);
        assert_eq!(pledgeable.get_pledger_count(), expected_pledger_count - 1);
        assert_eq!(pledgeable.get(middle_pledger), 0);
    }

    #[test]
    fn test_remove_last_1000_pledgers() {
        let mut pledgeable: TestingState = Default::default();

        // set up 1000 pledgers
        let expected_pledger_count: u32 = 1000;
        let mut expected_total: u256 = 0; // actual value set up in the while loop

        let mut i: felt252 = expected_pledger_count.into();
        let last_pledger: ContractAddress = i.try_into().unwrap();
        let last_amount = 100000;
        i -= 1; // leave place for the last pledger

        while i != 0 {
            let pledger: ContractAddress = i.try_into().unwrap();
            let amount: u256 = i.into() * 100;
            pledgeable.add(pledger, amount);
            expected_total += amount;
            i -= 1;
        };

        // add last pledger        
        pledgeable.add(last_pledger, last_amount);
        expected_total += last_amount;

        assert_eq!(pledgeable.get_total(), expected_total);
        assert_eq!(pledgeable.get_pledger_count(), expected_pledger_count);
        assert_eq!(pledgeable.get(last_pledger), last_amount);

        let removed_amount = pledgeable.remove(last_pledger);

        expected_total -= last_amount;

        assert_eq!(removed_amount, last_amount);
        assert_eq!(pledgeable.get_total(), expected_total);
        assert_eq!(pledgeable.get_pledger_count(), expected_pledger_count - 1);
        assert_eq!(pledgeable.get(last_pledger), 0);
    }

    #[test]
    fn test_get_pledgers_as_arr() {
        let mut pledgeable: TestingState = Default::default();
        let pledger_1 = contract_address_const::<'pledger_1'>();
        let pledger_2 = contract_address_const::<'pledger_2'>();
        let pledger_3 = contract_address_const::<'pledger_3'>();

        pledgeable.add(pledger_1, 1000);
        pledgeable.add(pledger_2, 500);
        pledgeable.add(pledger_3, 2500);
        // 2nd pledge by pledger_2 *should not* increase the pledge count
        pledgeable.add(pledger_2, 1500);

        let pledgers_arr = pledgeable.get_pledgers_as_arr();

        assert_eq!(pledgers_arr.len(), 3);
        assert_eq!(pledger_1, *pledgers_arr[0]);
        assert_eq!(1000, pledgeable.get(*pledgers_arr[0]));
        assert_eq!(pledger_2, *pledgers_arr[1]);
        assert_eq!(2000, pledgeable.get(*pledgers_arr[1]));
        assert_eq!(pledger_3, *pledgers_arr[2]);
        assert_eq!(2500, pledgeable.get(*pledgers_arr[2]));
    }

    #[test]
    fn test_get_pledgers_as_arr_many_pledgers() {
        let mut pledgeable: TestingState = Default::default();

        // set up 1000 pledgers
        let mut pledgers: Array::<ContractAddress> = array![];
        let mut i: felt252 = 1000;
        while i != 0 {
            let pledger: ContractAddress = i.try_into().unwrap();
            let amount: u256 = i.into() * 100;
            pledgeable.add(pledger, amount);
            pledgers.append(pledger);
            i -= 1;
        };

        let pledgers_arr: Array::<ContractAddress> = pledgeable.get_pledgers_as_arr();

        assert_eq!(pledgers_arr.len(), pledgers.len());

        let mut i = 0;
        while i < 1000 {
            let expected_pledger: ContractAddress = *pledgers.at(i);
            let actual_pledger: ContractAddress = *pledgers_arr.at(i);
            assert_eq!(expected_pledger, actual_pledger);
            i += 1;
        }
    }

    #[test]
    fn test_get() {
        let mut pledgeable: TestingState = Default::default();
        let pledger_1 = contract_address_const::<'pledger_1'>();
        let pledger_2 = contract_address_const::<'pledger_2'>();
        let pledger_3 = contract_address_const::<'pledger_3'>();

        pledgeable.add(pledger_1, 1000);
        pledgeable.add(pledger_2, 500);
        // pledger_3 not added

        assert_eq!(pledgeable.get(pledger_1), 1000);
        assert_eq!(pledgeable.get(pledger_2), 500);
        assert_eq!(pledgeable.get(pledger_3), 0);
    }
}
