use core::traits::TryInto;
use core::clone::Clone;
use core::result::ResultTrait;
use starknet::{
    ContractAddress, ClassHash, get_block_timestamp, contract_address_const, get_caller_address
};
use snforge_std::{
    declare, ContractClass, ContractClassTrait, start_cheat_caller_address,
    stop_cheat_caller_address, spy_events, SpyOn, EventSpy, EventAssertions, get_class_hash
};

use advanced_factory::campaign::{Campaign, ICampaignDispatcher, ICampaignDispatcherTrait};
use components::ownable::{IOwnableDispatcher, IOwnableDispatcherTrait};

/// Deploy a campaign contract with the provided data
fn deploy_with(
    title: ByteArray, description: ByteArray, target: u256, duration: u64, token: ContractAddress
) -> ICampaignDispatcher {
    let owner = contract_address_const::<'owner'>();
    let mut calldata: Array::<felt252> = array![];
    ((owner, title, description, target), duration, token).serialize(ref calldata);

    let contract = declare("Campaign").unwrap();
    let contract_address = contract.precalculate_address(@calldata);
    let factory = contract_address_const::<'factory'>();
    start_cheat_caller_address(contract_address, factory);

    contract.deploy(@calldata).unwrap();

    stop_cheat_caller_address(contract_address);

    ICampaignDispatcher { contract_address }
}

/// Deploy a campaign contract with default data
fn deploy() -> ICampaignDispatcher {
    deploy_with("title 1", "description 1", 10000, 60, contract_address_const::<'token'>())
}

#[test]
fn test_deploy() {
    let campaign = deploy();

    assert_eq!(campaign.get_title(), "title 1");
    assert_eq!(campaign.get_description(), "description 1");
    assert_eq!(campaign.get_target(), 10000);
    assert_eq!(campaign.get_end_time(), get_block_timestamp() + 60);

    let owner: ContractAddress = contract_address_const::<'owner'>();
    let campaign_ownable = IOwnableDispatcher { contract_address: campaign.contract_address };
    assert_eq!(campaign_ownable.owner(), owner);
}

#[test]
fn test_upgrade_class_hash() {
    let campaign = deploy();

    let mut spy = spy_events(SpyOn::One(campaign.contract_address));

    let new_class_hash = declare("Campaign_Updated").unwrap().class_hash;

    let factory = contract_address_const::<'factory'>();
    start_cheat_caller_address(campaign.contract_address, factory);

    if let Result::Err(errs) = campaign.upgrade(new_class_hash) {
        panic(errs)
    }

    assert_eq!(get_class_hash(campaign.contract_address), new_class_hash);

    spy
        .assert_emitted(
            @array![
                (
                    campaign.contract_address,
                    Campaign::Event::Upgraded(Campaign::Upgraded { implementation: new_class_hash })
                )
            ]
        );
}

#[test]
#[should_panic(expected: 'Caller not factory')]
fn test_upgrade_class_hash_fail() {
    let campaign = deploy();

    let new_class_hash = declare("Campaign_Updated").unwrap().class_hash;

    let owner = contract_address_const::<'owner'>();
    start_cheat_caller_address(campaign.contract_address, owner);

    if let Result::Err(errs) = campaign.upgrade(new_class_hash) {
        panic(errs)
    }
}

