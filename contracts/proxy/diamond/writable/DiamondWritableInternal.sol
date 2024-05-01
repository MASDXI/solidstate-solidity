// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import { AddressUtils } from '../../../utils/AddressUtils.sol';
import { DiamondBaseStorage } from '../base/DiamondBaseStorage.sol';
import { IDiamondWritableInternal } from './IDiamondWritableInternal.sol';
import 'hardhat/console.sol';

abstract contract DiamondWritableInternal is IDiamondWritableInternal {
    using AddressUtils for address;

    bytes32 private constant CLEAR_ADDRESS_MASK =
        bytes32(uint256(0xffffffffffffffffffffffff));
    bytes32 private constant CLEAR_SELECTOR_MASK =
        bytes32(uint256(0xffffffff << 224));

    /**
     * @notice update functions callable on Diamond proxy
     * @param facetCuts array of structured Diamond facet update data
     * @param target optional recipient of initialization delegatecall
     * @param data optional initialization call data
     */
    function _diamondCut(
        FacetCut[] memory facetCuts,
        address target,
        bytes memory data
    ) internal virtual {
        DiamondBaseStorage.Layout storage l = DiamondBaseStorage.layout();

        unchecked {
            // record selector count at start of operation for later comparison
            uint256 originalSelectorCount = l.selectorCount;
            // maintain an up-to-date selector count in the stack
            uint256 selectorCount = originalSelectorCount;
            // declare a 32-byte sequence of up to 8 function selectors
            bytes32 slug;

            // if selector count is not a multiple of 8, load the last slug because it is not full
            // else leave the default zero-bytes value as is, and use it as a new slug
            if (selectorCount & 7 > 0) {
                slug = l.selectorSlugs[selectorCount >> 3];
            }

            // process each facet cut struct according to its action
            // selector count and slug are passed in and read back out to avoid duplicate storage reads
            for (uint256 i; i < facetCuts.length; i++) {
                FacetCut memory facetCut = facetCuts[i];
                FacetCutAction action = facetCut.action;

                if (facetCut.selectors.length == 0)
                    revert DiamondWritable__SelectorNotSpecified();

                if (action == FacetCutAction.ADD) {
                    (selectorCount, slug) = _addFacetSelectors(
                        l,
                        selectorCount,
                        slug,
                        facetCut
                    );
                } else if (action == FacetCutAction.REPLACE) {
                    _replaceFacetSelectors(l, facetCut);
                } else if (action == FacetCutAction.REMOVE) {
                    (selectorCount, slug) = _removeFacetSelectors(
                        l,
                        selectorCount,
                        slug,
                        facetCut
                    );
                }
            }

            // if selector count has changed, update it in storage
            if (selectorCount != originalSelectorCount) {
                l.selectorCount = uint16(selectorCount);
            }

            // if final selector count is not a multiple of 8, write the slug to storage
            // else it was already written to storage by the add/remove loops
            if (selectorCount & 7 > 0) {
                l.selectorSlugs[selectorCount >> 3] = slug;
            }

            emit DiamondCut(facetCuts, target, data);
            _initialize(target, data);
        }
    }

    function _addFacetSelectors(
        DiamondBaseStorage.Layout storage l,
        uint256 selectorCount,
        bytes32 slug,
        FacetCut memory facetCut
    ) internal returns (uint256, bytes32) {
        unchecked {
            if (facetCut.target.isContract()) {
                if (facetCut.target == address(this)) {
                    revert DiamondWritable__SelectorIsImmutable();
                }
            } else if (facetCut.target != address(this)) {
                revert DiamondWritable__TargetHasNoCode();
            }

            for (uint256 i; i < facetCut.selectors.length; i++) {
                bytes4 selector = facetCut.selectors[i];
                bytes32 oldFacet = l.facets[selector];

                if (address(bytes20(oldFacet)) != address(0))
                    revert DiamondWritable__SelectorAlreadyAdded();

                // for current selector, write facet address and global index to storage
                l.facets[selector] =
                    bytes20(facetCut.target) |
                    bytes32(selectorCount);

                // calculate bit position of current selector within 256-bit slug
                uint256 selectorBitIndex = (selectorCount & 7) << 5;

                // clear a space in the slug and insert the current selector
                slug =
                    (slug & ~(CLEAR_SELECTOR_MASK >> selectorBitIndex)) |
                    (bytes32(selector) >> selectorBitIndex);

                // if slug is now full, write it to storage and continue with an empty slug
                if (selectorBitIndex == 224) {
                    l.selectorSlugs[selectorCount >> 3] = slug;
                    slug = 0;
                }

                selectorCount++;
            }

            return (selectorCount, slug);
        }
    }

    function _removeFacetSelectors(
        DiamondBaseStorage.Layout storage l,
        uint256 selectorCount,
        bytes32 slug,
        FacetCut memory facetCut
    ) internal returns (uint256, bytes32) {
        unchecked {
            if (facetCut.target != address(0))
                revert DiamondWritable__RemoveTargetNotZeroAddress();

            // calculate the total number of 32-byte sequences
            uint256 slugCount = selectorCount >> 3;
            uint256 selectorInSlugIndex = selectorCount & 7;

            for (uint256 i; i < facetCut.selectors.length; i++) {
                bytes4 selector = facetCut.selectors[i];
                bytes32 oldFacet = l.facets[selector];

                if (address(bytes20(oldFacet)) == address(0))
                    revert DiamondWritable__SelectorNotFound();

                if (address(bytes20(oldFacet)) == address(this))
                    revert DiamondWritable__SelectorIsImmutable();

                if (slug == 0) {
                    slugCount--;
                    slug = l.selectorSlugs[slugCount];
                    selectorInSlugIndex = 7;
                } else {
                    selectorInSlugIndex--;
                }

                bytes4 lastSelector;
                uint256 oldSlugCount;
                uint256 oldSelectorBitIndex;

                // adding a block here prevents stack-too-deep error
                {
                    // replace selector with last selector in l.facets
                    lastSelector = bytes4(slug << (selectorInSlugIndex << 5));

                    if (lastSelector != selector) {
                        // update last slug position info
                        l.facets[lastSelector] =
                            (oldFacet & CLEAR_ADDRESS_MASK) |
                            bytes20(l.facets[lastSelector]);
                    }

                    delete l.facets[selector];
                    uint256 oldSelectorCount = uint16(uint256(oldFacet));
                    oldSlugCount = oldSelectorCount >> 3;
                    oldSelectorBitIndex = (oldSelectorCount & 7) << 5;
                }

                if (oldSlugCount != slugCount) {
                    bytes32 oldSlug = l.selectorSlugs[oldSlugCount];

                    // clears the selector we are deleting and puts the last selector in its place.
                    oldSlug =
                        (oldSlug &
                            ~(CLEAR_SELECTOR_MASK >> oldSelectorBitIndex)) |
                        (bytes32(lastSelector) >> oldSelectorBitIndex);

                    // update storage with the modified slug
                    l.selectorSlugs[oldSlugCount] = oldSlug;
                } else {
                    // clears the selector we are deleting and puts the last selector in its place.
                    slug =
                        (slug & ~(CLEAR_SELECTOR_MASK >> oldSelectorBitIndex)) |
                        (bytes32(lastSelector) >> oldSelectorBitIndex);
                }

                // if slug is empty, delete it from storage and continue with an empty slug
                if (selectorInSlugIndex == 0) {
                    delete l.selectorSlugs[slugCount];
                    slug = 0;
                }
            }

            selectorCount = (slugCount << 3) | selectorInSlugIndex;

            return (selectorCount, slug);
        }
    }

    function _replaceFacetSelectors(
        DiamondBaseStorage.Layout storage l,
        FacetCut memory facetCut
    ) internal {
        unchecked {
            if (!facetCut.target.isContract())
                revert DiamondWritable__TargetHasNoCode();

            for (uint256 i; i < facetCut.selectors.length; i++) {
                bytes4 selector = facetCut.selectors[i];
                bytes32 oldFacet = l.facets[selector];
                address oldFacetAddress = address(bytes20(oldFacet));

                if (oldFacetAddress == address(0))
                    revert DiamondWritable__SelectorNotFound();
                if (oldFacetAddress == address(this))
                    revert DiamondWritable__SelectorIsImmutable();
                if (oldFacetAddress == facetCut.target)
                    revert DiamondWritable__ReplaceTargetIsIdentical();

                // replace old facet address
                l.facets[selector] =
                    (oldFacet & CLEAR_ADDRESS_MASK) |
                    bytes20(facetCut.target);
            }
        }
    }

    function _initialize(address target, bytes memory data) private {
        if ((target == address(0)) != (data.length == 0))
            revert DiamondWritable__InvalidInitializationParameters();

        if (target != address(0)) {
            if (target != address(this)) {
                if (!target.isContract())
                    revert DiamondWritable__TargetHasNoCode();
            }

            (bool success, ) = target.delegatecall(data);

            if (!success) {
                assembly {
                    returndatacopy(0, 0, returndatasize())
                    revert(0, returndatasize())
                }
            }
        }
    }
}
