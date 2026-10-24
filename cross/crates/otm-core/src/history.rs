//! A fixed number of recent readings, oldest first: memory stays bounded
//! however long the app runs.

use std::collections::VecDeque;

#[derive(Clone, Debug)]
pub struct Ring<T> {
    items: VecDeque<T>,
    capacity: usize,
}

impl<T> Ring<T> {
    /// A ring holding at most `capacity` items (at least one).
    pub fn new(capacity: usize) -> Self {
        let capacity = capacity.max(1);
        Self { items: VecDeque::with_capacity(capacity), capacity }
    }

    /// Adds `item`, dropping the oldest when full.
    pub fn push(&mut self, item: T) {
        if self.items.len() == self.capacity {
            self.items.pop_front();
        }
        self.items.push_back(item);
    }

    pub fn capacity(&self) -> usize {
        self.capacity
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    /// Oldest first.
    pub fn iter(&self) -> impl DoubleEndedIterator<Item = &T> + ExactSizeIterator {
        self.items.iter()
    }

    pub fn last(&self) -> Option<&T> {
        self.items.back()
    }
}

impl<T: Clone> Ring<T> {
    /// A copy, oldest first.
    pub fn to_vec(&self) -> Vec<T> {
        self.items.iter().cloned().collect()
    }
}

#[cfg(test)]
mod tests {
    use super::Ring;

    #[test]
    fn keeps_the_newest_items_oldest_first() {
        let mut ring = Ring::new(3);
        for value in 1..=5 {
            ring.push(value);
        }
        assert_eq!(ring.to_vec(), vec![3, 4, 5]);
        assert_eq!(ring.last(), Some(&5));
        assert_eq!(ring.len(), 3);
    }

    #[test]
    fn a_zero_capacity_still_holds_the_latest() {
        let mut ring = Ring::new(0);
        ring.push('a');
        ring.push('b');
        assert_eq!(ring.capacity(), 1);
        assert_eq!(ring.to_vec(), vec!['b']);
    }
}
