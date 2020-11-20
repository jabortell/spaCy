# cython: profile=True, cdivision=True, infer_types=True
from cymem.cymem cimport Pool, Address
from libc.stdint cimport int32_t

from collections import defaultdict, Counter

from ...typedefs cimport hash_t, attr_t
from ...strings cimport hash_string
from ...structs cimport TokenC
from ...tokens.doc cimport Doc, set_children_from_heads
from ...training.example cimport Example
from .stateclass cimport StateClass
from ._state cimport StateC

from ...errors import Errors

cdef weight_t MIN_SCORE = -90000
cdef attr_t SUBTOK_LABEL = hash_string(u'subtok')

DEF NON_MONOTONIC = True

cdef enum:
    SHIFT
    REDUCE
    LEFT
    RIGHT

    BREAK

    N_MOVES


MOVE_NAMES = [None] * N_MOVES
MOVE_NAMES[SHIFT] = 'S'
MOVE_NAMES[REDUCE] = 'D'
MOVE_NAMES[LEFT] = 'L'
MOVE_NAMES[RIGHT] = 'R'
MOVE_NAMES[BREAK] = 'B'


cdef enum:
    HEAD_IN_STACK = 0
    HEAD_IN_BUFFER
    HEAD_UNKNOWN
    IS_SENT_START
    SENT_START_UNKNOWN


cdef struct GoldParseStateC:
    char* state_bits
    int32_t* n_kids_in_buffer
    int32_t* n_kids_in_stack
    int32_t* heads
    attr_t* labels
    int32_t** kids
    int32_t* n_kids
    int32_t length
    int32_t stride


cdef GoldParseStateC create_gold_state(Pool mem, StateClass stcls,
        heads, labels, sent_starts) except *:
    cdef GoldParseStateC gs
    gs.length = len(heads)
    gs.stride = 1
    gs.labels = <attr_t*>mem.alloc(gs.length, sizeof(gs.labels[0]))
    gs.heads = <int32_t*>mem.alloc(gs.length, sizeof(gs.heads[0]))
    gs.n_kids = <int32_t*>mem.alloc(gs.length, sizeof(gs.n_kids[0]))
    gs.state_bits = <char*>mem.alloc(gs.length, sizeof(gs.state_bits[0]))
    gs.n_kids_in_buffer = <int32_t*>mem.alloc(gs.length, sizeof(gs.n_kids_in_buffer[0]))
    gs.n_kids_in_stack = <int32_t*>mem.alloc(gs.length, sizeof(gs.n_kids_in_stack[0]))

    for i, is_sent_start in enumerate(sent_starts):
        if is_sent_start == True:
            gs.state_bits[i] = set_state_flag(
                gs.state_bits[i],
                IS_SENT_START,
                1
            )
            gs.state_bits[i] = set_state_flag(
                gs.state_bits[i],
                SENT_START_UNKNOWN,
                0
            )

        elif is_sent_start is None:
            gs.state_bits[i] = set_state_flag(
                gs.state_bits[i],
                SENT_START_UNKNOWN,
                1
            )
            gs.state_bits[i] = set_state_flag(
                gs.state_bits[i],
                IS_SENT_START,
                0
            )
        else:
            gs.state_bits[i] = set_state_flag(
                gs.state_bits[i],
                SENT_START_UNKNOWN,
                0
            )
            gs.state_bits[i] = set_state_flag(
                gs.state_bits[i],
                IS_SENT_START,
                0
            )

    for i, (head, label) in enumerate(zip(heads, labels)):
        if head is not None:
            gs.heads[i] = head
            gs.labels[i] = label
            if i != head:
                gs.n_kids[head] += 1
            gs.state_bits[i] = set_state_flag(
                gs.state_bits[i],
                HEAD_UNKNOWN,
                0
            )
        else:
            gs.state_bits[i] = set_state_flag(
                gs.state_bits[i],
                HEAD_UNKNOWN,
                1
            )
    # Make an array of pointers, pointing into the gs_kids_flat array.
    gs.kids = <int32_t**>mem.alloc(gs.length, sizeof(int32_t*))
    for i in range(gs.length):
        if gs.n_kids[i] != 0:
            gs.kids[i] = <int32_t*>mem.alloc(gs.n_kids[i], sizeof(int32_t))
    # This is a temporary buffer
    js_addr = Address(gs.length, sizeof(int32_t))
    js = <int32_t*>js_addr.ptr
    for i in range(gs.length):
        if not is_head_unknown(&gs, i):
            head = gs.heads[i]
            if head != i:
                gs.kids[head][js[head]] = i
                js[head] += 1
    return gs


cdef void update_gold_state(GoldParseStateC* gs, StateC* s) nogil:
    for i in range(gs.length):
        gs.state_bits[i] = set_state_flag(
            gs.state_bits[i],
            HEAD_IN_BUFFER,
            0
        )
        gs.state_bits[i] = set_state_flag(
            gs.state_bits[i],
            HEAD_IN_STACK,
            0
        )
        gs.n_kids_in_stack[i] = 0
        gs.n_kids_in_buffer[i] = 0

    for i in range(s.stack_depth()):
        s_i = s.S(i)
        if not is_head_unknown(gs, s_i):
            gs.n_kids_in_stack[gs.heads[s_i]] += 1
        for kid in gs.kids[s_i][:gs.n_kids[s_i]]:
            gs.state_bits[kid] = set_state_flag(
                gs.state_bits[kid],
                HEAD_IN_STACK,
                1
            )
    for i in range(s.buffer_length()):
        b_i = s.B(i)
        if s.is_sent_start(b_i):
            break
        if not is_head_unknown(gs, b_i):
            gs.n_kids_in_buffer[gs.heads[b_i]] += 1
        for kid in gs.kids[b_i][:gs.n_kids[b_i]]:
            gs.state_bits[kid] = set_state_flag(
                gs.state_bits[kid],
                HEAD_IN_BUFFER,
                1
            )


cdef class ArcEagerGold:
    cdef GoldParseStateC c
    cdef Pool mem

    def __init__(self, ArcEager moves, StateClass stcls, Example example):
        self.mem = Pool()
        heads, labels = example.get_aligned_parse(projectivize=True)
        labels = [label if label is not None else "" for label in labels]
        labels = [example.x.vocab.strings.add(label) for label in labels]
        sent_starts = example.get_aligned("SENT_START")
        assert len(heads) == len(labels) == len(sent_starts)
        self.c = create_gold_state(self.mem, stcls, heads, labels, sent_starts)

    def update(self, StateClass stcls):
        update_gold_state(&self.c, stcls.c)


cdef int check_state_gold(char state_bits, char flag) nogil:
    cdef char one = 1
    return state_bits & (one << flag)


cdef int set_state_flag(char state_bits, char flag, int value) nogil:
    cdef char one = 1
    if value:
        return state_bits | (one << flag)
    else:
        return state_bits & ~(one << flag)


cdef int is_head_in_stack(const GoldParseStateC* gold, int i) nogil:
    return check_state_gold(gold.state_bits[i], HEAD_IN_STACK)


cdef int is_head_in_buffer(const GoldParseStateC* gold, int i) nogil:
    return check_state_gold(gold.state_bits[i], HEAD_IN_BUFFER)


cdef int is_head_unknown(const GoldParseStateC* gold, int i) nogil:
    return check_state_gold(gold.state_bits[i], HEAD_UNKNOWN)

cdef int is_sent_start(const GoldParseStateC* gold, int i) nogil:
    return check_state_gold(gold.state_bits[i], IS_SENT_START)

cdef int is_sent_start_unknown(const GoldParseStateC* gold, int i) nogil:
    return check_state_gold(gold.state_bits[i], SENT_START_UNKNOWN)


# Helper functions for the arc-eager oracle

cdef weight_t push_cost(StateClass stcls, const void* _gold, int target) nogil:
    gold = <const GoldParseStateC*>_gold
    cdef weight_t cost = 0
    if is_head_in_stack(gold, target):
        cost += 1
    cost += gold.n_kids_in_stack[target]
    if stcls.c.buffer_length() >= 2 and not stcls.c.is_sent_start(stcls.c.B(1)):
        if is_sent_start(gold, stcls.c.B(1)):
            cost += 1
    return cost


cdef weight_t pop_cost(StateClass stcls, const void* _gold, int target) nogil:
    gold = <const GoldParseStateC*>_gold
    cdef weight_t cost = 0
    if is_head_in_buffer(gold, target):
        cost += 1
    cost += gold[0].n_kids_in_buffer[target]
    return cost


cdef weight_t arc_cost(StateClass stcls, const void* _gold, int head, int child) nogil:
    gold = <const GoldParseStateC*>_gold
    if arc_is_gold(gold, head, child):
        return 0
    elif stcls.c.H(child) == gold.heads[child]:
        return 1
    # Head in buffer
    elif is_head_in_buffer(gold, child):
        return 1
    else:
        return 0


cdef bint arc_is_gold(const GoldParseStateC* gold, int head, int child) nogil:
    if is_head_unknown(gold, child):
        return True
    elif gold.heads[child] == head:
        return True
    else:
        return False


cdef bint label_is_gold(const GoldParseStateC* gold, int child, attr_t label) nogil:
    if is_head_unknown(gold, child):
        return True
    elif label == 0:
        return True
    elif gold.labels[child] == label:
        return True
    else:
        return False


cdef bint _is_gold_root(const GoldParseStateC* gold, int word) nogil:
    return gold.heads[word] == word or is_head_unknown(gold, word)


cdef class Shift:
    """Move the first word of the buffer onto the stack and mark it as "shifted"

    Validity:
    * At least one word in buffer
    * Word has not been shifted before
    * If stack isn't empty, word is not the start of a sentence.

    Cost:
    * Arcs between stack and B[0]

    Action:
    * Mark B[0] as 'shifted'
    * Push stack
    * Advance buffer
    """
    @staticmethod
    cdef bint is_valid(const StateC* st, attr_t label) nogil:
        if st.eol():
            return 0
        elif st.stack_depth() == 0:
            return 1
        elif st.is_sent_start(st.B(0)):
            return 0
        elif st.shifted[st.B(0)]:
            return 0
        else:
            return 1

    @staticmethod
    cdef int transition(StateC* st, attr_t label) nogil:
        st.push()

    @staticmethod
    cdef weight_t cost(StateClass st, const void* _gold, attr_t label) nogil:
        gold = <const GoldParseStateC*>_gold
        return Shift.move_cost(st, gold) + Shift.label_cost(st, gold, label)

    @staticmethod
    cdef inline weight_t move_cost(StateClass s, const void* _gold) nogil:
        gold = <const GoldParseStateC*>_gold
        return push_cost(s, gold, s.c.B(0))

    @staticmethod
    cdef inline weight_t label_cost(StateClass s, const void* _gold, attr_t label) nogil:
        return 0


cdef class Reduce:
    """
    Pop from the stack. If it has no head and the stack isn't empty, place
    it back on the buffer.

    Validity:
    * Stack not empty

    Cost:
    * If B[0] is the start of a sentence, cost is 0
    * Arcs between stack and buffer
    * If arc has no head, we're saving arcs between S[0] and S[1:], so decrement
        cost by those arcs.
    """
    @staticmethod
    cdef bint is_valid(const StateC* st, attr_t label) nogil:
        if st.stack_depth() == 0:
            return False
        if st.stack_depth() >= 2:
            return True
        elif st.eol():
            return True
        elif st.is_sent_start(st.B(0)):
            return True
        else:
            return False

    @staticmethod
    cdef int transition(StateC* st, attr_t label) nogil:
        if st.has_head(st.S(0)) or st.stack_depth() == 1:
            st.pop()
        else:
            st.unshift()

    @staticmethod
    cdef weight_t cost(StateClass s, const void* _gold, attr_t label) nogil:
        gold = <const GoldParseStateC*>_gold
        return Reduce.move_cost(s, gold) + Reduce.label_cost(s, gold, label)

    @staticmethod
    cdef inline weight_t move_cost(StateClass st, const void* _gold) nogil:
        gold = <const GoldParseStateC*>_gold
        if st.c.is_sent_start(st.c.B(0)):
            return 0
        s0 = st.c.S(0)
        cost = pop_cost(st, gold, s0)
        return_to_buffer = not st.c.has_head(s0)
        if return_to_buffer:
            # Decrement cost for the arcs we save, as we'll be putting this
            # back to the buffer
            if is_head_in_stack(gold, s0):
                cost -= 1
            cost -= gold.n_kids_in_stack[s0]
        return cost

    @staticmethod
    cdef inline weight_t label_cost(StateClass s, const void* gold, attr_t label) nogil:
        return 0


cdef class LeftArc:
    """Add an arc between B[0] and S[0], replacing the previous head of S[0] if
    one is set. Pop S[0] from the stack.

    Validity:
    * len(S) >= 1
    * len(B) >= 1
    * not is_sent_start(B[0])

    Cost:
    * Arcs between S[0] and buffer[1:]
    * If S[0] has a correct head, that arc
    * If S[0] has an incorrect head, minus that cost
    * If S[0] does not have a head, arcs between S[0] and S[1:]
    """
    @staticmethod
    cdef bint is_valid(const StateC* st, attr_t label) nogil:
        if st.stack_depth() == 0:
            return 0
        elif st.eol():
            return 0
        elif st.is_sent_start(st.B(0)):
            return 0
        elif label == SUBTOK_LABEL and st.S(0) != (st.B(0)-1):
            return 0
        else:
            return 1

    @staticmethod
    cdef int transition(StateC* st, attr_t label) nogil:
        st.add_arc(st.B(0), st.S(0), label)
        st.pop()
        #st.fast_forward()

    @staticmethod
    cdef inline weight_t cost(StateClass stcls, const void* _gold, attr_t label) nogil:
        gold = <const GoldParseStateC*>_gold
        return LeftArc.move_cost(stcls, gold) + LeftArc.label_cost(stcls, gold, label)

    @staticmethod
    cdef inline weight_t move_cost(StateClass stcls, const GoldParseStateC* gold) nogil:
        cdef weight_t cost = 0
        s = stcls.c
        s0 = s.S(0)
        b0 = s.B(0)
        if arc_is_gold(gold, b0, s0):
            # Have a negative cost if we 'recover' from the wrong dependency
            return 0 if not s.has_head(s0) else -1
        else:
            # Account for deps we might lose between S0 and stack
            if not s.has_head(s0):
                cost += gold.n_kids_in_stack[s0]
                if is_head_in_buffer(gold, s0):
                    cost += 1
            return cost + pop_cost(stcls, gold, s.S(0)) + arc_cost(stcls, gold, s.B(0), s.S(0))

    @staticmethod
    cdef inline weight_t label_cost(StateClass stcls, const GoldParseStateC* gold, attr_t label) nogil:
        s = stcls.c
        return arc_is_gold(gold, s.B(0), s.S(0)) and not label_is_gold(gold, s.S(0), label)


cdef class RightArc:
    """
    Add an arc from S[0] to B[0]. Push B[0].

    Validity:
    * len(S) >= 1
    * len(B) >= 1
    * not is_sent_start(B[0])

    Cost:
    * Arcs from B[0] to S
    * Arcs from S[1:] to B[0]
    * Arcs from B[1:] to B[0]
    """
    @staticmethod
    cdef bint is_valid(const StateC* st, attr_t label) nogil:
        if st.stack_depth() == 0:
            return 0
        elif st.eol():
            return 0
        elif st.is_sent_start(st.B(0)):
            return 0
        elif label == SUBTOK_LABEL and st.S(0) != (st.B(0)-1):
            # If there's (perhaps partial) parse pre-set, don't allow cycle.
            return 0
        else:
            return 1

    @staticmethod
    cdef int transition(StateC* st, attr_t label) nogil:
        st.add_arc(st.S(0), st.B(0), label)
        st.push()

    @staticmethod
    cdef inline weight_t cost(StateClass stcls, const void* _gold, attr_t label) nogil:
        s = stcls.c
        gold = <const GoldParseStateC*>_gold
        return RightArc.move_cost(stcls, gold) + RightArc.label_cost(stcls, gold, label)

    @staticmethod
    cdef inline weight_t move_cost(StateClass stcls, const void* _gold) nogil:
        s = stcls.c
        gold = <const GoldParseStateC*>_gold
        if arc_is_gold(gold, s.S(0), s.B(0)):
            return 0
        elif s.shifted[s.B(0)]:
            return push_cost(stcls, gold, s.B(0))
        else:
            return push_cost(stcls, gold, s.B(0)) + arc_cost(stcls, gold, s.S(0), s.B(0))

    @staticmethod
    cdef weight_t label_cost(StateClass stcls, const void* _gold, attr_t label) nogil:
        s = stcls.c
        gold = <const GoldParseStateC*>_gold
        return arc_is_gold(gold, s.S(0), s.B(0)) and not label_is_gold(gold, s.B(0), label)


cdef class Break:
    """Mark the second word of the buffer as the start of a 
    sentence. 

    Validity:
    * len(buffer) >= 2
    * B[1] == B[0] + 1
    * not is_sent_start(B[1])

    Action:
    * mark_sent_start(B[1])

    Cost:
    * not is_sent_start(B[1])
    * Arcs between B[0] and B[1:]
    * Arcs between S and B[1]
    """
    @staticmethod
    cdef bint is_valid(const StateC* st, attr_t label) nogil:
        cdef int i
        if st.buffer_length() < 2:
            return False
        elif st.B(1) != st.B(0) + 1:
            return False
        elif st.is_sent_start(st.B(1)):
            return False
        else:
            return True

    @staticmethod
    cdef int transition(StateC* st, attr_t label) nogil:
        st.set_sent_start(st.B(1))

    @staticmethod
    cdef weight_t cost(StateClass stcls, const void* _gold, attr_t label) nogil:
        gold = <const GoldParseStateC*>_gold
        return Break.move_cost(stcls, gold) + Break.label_cost(stcls, gold, label)

    @staticmethod
    cdef inline weight_t move_cost(StateClass stcls, const void* _gold) nogil:
        s = stcls.c
        gold = <const GoldParseStateC*>_gold
        cdef int b0 = s.B(0)
        cdef int cost = 0
        cdef int si
        for i in range(s.stack_depth()):
            si = s.S(i)
            if is_head_in_buffer(gold, si):
                cost += 1
            cost += gold.n_kids_in_buffer[si]
            # We need to score into B[1:], so subtract deps that are at b0
            if gold.heads[b0] == si:
                cost -= 1
            if gold.heads[si] == b0:
                cost -= 1

        if not is_sent_start(gold, s.B(1)) \
        and not is_sent_start_unknown(gold, s.B(1)):
            cost += 1
        return cost

    @staticmethod
    cdef inline weight_t label_cost(StateClass stcls, const void* gold, attr_t label) nogil:
        return 0


cdef void* _init_state(Pool mem, int length, void* tokens) except NULL:
    st = new StateC(<const TokenC*>tokens, length)
    return <void*>st


cdef int _del_state(Pool mem, void* state, void* x) except -1:
    cdef StateC* st = <StateC*>state
    del st


cdef class ArcEager(TransitionSystem):
    def __init__(self, *args, **kwargs):
        TransitionSystem.__init__(self, *args, **kwargs)
        self.init_beam_state = _init_state
        self.del_beam_state = _del_state

    @classmethod
    def get_actions(cls, **kwargs):
        min_freq = kwargs.get('min_freq', None)
        actions = defaultdict(lambda: Counter())
        actions[SHIFT][''] = 1
        actions[REDUCE][''] = 1
        for label in kwargs.get('left_labels', []):
            actions[LEFT][label] = 1
            actions[SHIFT][label] = 1
        for label in kwargs.get('right_labels', []):
            actions[RIGHT][label] = 1
            actions[REDUCE][label] = 1
        for example in kwargs.get('examples', []):
            heads, labels = example.get_aligned_parse(projectivize=True)
            for child, (head, label) in enumerate(zip(heads, labels)):
                if head is None or label is None:
                    continue
                if label.upper() == 'ROOT' :
                    label = 'ROOT'
                if head == child:
                    actions[BREAK][label] += 1
                if head < child:
                    actions[RIGHT][label] += 1
                    actions[REDUCE][''] += 1
                elif head > child:
                    actions[LEFT][label] += 1
                    actions[SHIFT][''] += 1
        if min_freq is not None:
            for action, label_freqs in actions.items():
                for label, freq in list(label_freqs.items()):
                    if freq < min_freq:
                        label_freqs.pop(label)
        # Ensure these actions are present
        actions[BREAK].setdefault('ROOT', 0)
        if kwargs.get("learn_tokens") is True:
            actions[RIGHT].setdefault('subtok', 0)
            actions[LEFT].setdefault('subtok', 0)
        # Used for backoff
        actions[RIGHT].setdefault('dep', 0)
        actions[LEFT].setdefault('dep', 0)
        return actions

    @property
    def action_types(self):
        return (SHIFT, REDUCE, LEFT, RIGHT, BREAK)

    def transition(self, StateClass state, action):
        cdef Transition t = self.lookup_transition(action)
        t.do(state.c, t.label)
        return state

    def is_gold_parse(self, StateClass state, ArcEagerGold gold):
        for i in range(state.c.length):
            token = state.c.safe_get(i)
            if not arc_is_gold(&gold.c, i, i+token.head):
                return False
            elif not label_is_gold(&gold.c, i, token.dep):
                return False
        return True

    def init_gold(self, StateClass state, Example example):
        gold = ArcEagerGold(self, state, example)
        self._replace_unseen_labels(gold)
        return gold

    def init_gold_batch(self, examples):
        all_states = self.init_batch([eg.predicted for eg in examples])
        golds = []
        states = []
        for state, eg in zip(all_states, examples):
            if self.has_gold(eg) and not state.is_final():
                golds.append(self.init_gold(state, eg))
                states.append(state)
        n_steps = sum([len(s.queue) for s in states])
        return states, golds, n_steps

    def _replace_unseen_labels(self, ArcEagerGold gold):
        backoff_label = self.strings["dep"]
        root_label = self.strings["ROOT"]
        left_labels = self.labels[LEFT]
        right_labels = self.labels[RIGHT]
        break_labels = self.labels[BREAK]
        for i in range(gold.c.length):
            if not is_head_unknown(&gold.c, i):
                head = gold.c.heads[i]
                label = self.strings[gold.c.labels[i]]
                if head > i and label not in left_labels:
                    gold.c.labels[i] = backoff_label
                elif head < i and label not in right_labels:
                    gold.c.labels[i] = backoff_label
                elif head == i and label not in break_labels:
                    gold.c.labels[i] = root_label
        return gold

    cdef Transition lookup_transition(self, object name_or_id) except *:
        if isinstance(name_or_id, int):
            return self.c[name_or_id]
        name = name_or_id
        if '-' in name:
            move_str, label_str = name.split('-', 1)
            label = self.strings[label_str]
        else:
            move_str = name
            label = 0
        move = MOVE_NAMES.index(move_str)
        for i in range(self.n_moves):
            if self.c[i].move == move and self.c[i].label == label:
                return self.c[i]
        raise KeyError(f"Unknown transition: {name}")

    def move_name(self, int move, attr_t label):
        label_str = self.strings[label]
        if label_str:
            return MOVE_NAMES[move] + '-' + label_str
        else:
            return MOVE_NAMES[move]

    def class_name(self, int i):
        return self.move_name(self.c[i].move, self.c[i].label)

    cdef Transition init_transition(self, int clas, int move, attr_t label) except *:
        # TODO: Apparent Cython bug here when we try to use the Transition()
        # constructor with the function pointers
        cdef Transition t
        t.score = 0
        t.clas = clas
        t.move = move
        t.label = label
        if move == SHIFT:
            t.is_valid = Shift.is_valid
            t.do = Shift.transition
            t.get_cost = Shift.cost
        elif move == REDUCE:
            t.is_valid = Reduce.is_valid
            t.do = Reduce.transition
            t.get_cost = Reduce.cost
        elif move == LEFT:
            t.is_valid = LeftArc.is_valid
            t.do = LeftArc.transition
            t.get_cost = LeftArc.cost
        elif move == RIGHT:
            t.is_valid = RightArc.is_valid
            t.do = RightArc.transition
            t.get_cost = RightArc.cost
        elif move == BREAK:
            t.is_valid = Break.is_valid
            t.do = Break.transition
            t.get_cost = Break.cost
        else:
            raise ValueError(Errors.E019.format(action=move, src='arc_eager'))
        return t

    cdef int initialize_state(self, StateC* st) nogil:
        pass
        #st.fast_forward()

    cdef int finalize_state(self, StateC* st) nogil:
        cdef int i
        # TODO clean this up
        sent = <TokenC*>st._sent
        for i in range(st._arcs.size()):
            arc = st._arcs.at(i)
            if arc.head != -1 and arc.child != -1:
                sent[arc.child].head = arc.head - arc.child
                sent[arc.child].dep = arc.label
        for i in range(st.length):
            if sent[i].head == 0:
                sent[i].dep = self.root_label

    def finalize_doc(self, Doc doc):
        set_children_from_heads(doc.c, 0, doc.length)

    def has_gold(self, Example eg, start=0, end=None):
        for word in eg.y[start:end]:
            if word.dep != 0:
                return True
        else:
            return False

    cdef int set_valid(self, int* output, const StateC* st) nogil:
        cdef bint[N_MOVES] is_valid
        is_valid[SHIFT] = Shift.is_valid(st, 0)
        is_valid[REDUCE] = Reduce.is_valid(st, 0)
        is_valid[LEFT] = LeftArc.is_valid(st, 0)
        is_valid[RIGHT] = RightArc.is_valid(st, 0)
        #is_valid[BREAK] = Break.is_valid(st, 0)
        cdef int i
        for i in range(self.n_moves):
            if self.c[i].label == SUBTOK_LABEL:
                output[i] = self.c[i].is_valid(st, self.c[i].label)
            else:
                output[i] = is_valid[self.c[i].move]

    def get_cost(self, StateClass stcls, gold, int i):
        if not isinstance(gold, ArcEagerGold):
            raise TypeError(Errors.E909.format(name="ArcEagerGold"))
        cdef ArcEagerGold gold_ = gold
        gold_state = gold_.c
        n_gold = 0
        if self.c[i].is_valid(stcls.c, self.c[i].label):
            cost = self.c[i].get_cost(stcls, &gold_state, self.c[i].label)
        else:
            cost = 9000
        return cost

    cdef int set_costs(self, int* is_valid, weight_t* costs,
                       StateClass stcls, gold) except -1:
        if not isinstance(gold, ArcEagerGold):
            raise TypeError(Errors.E909.format(name="ArcEagerGold"))
        cdef ArcEagerGold gold_ = gold
        gold_.update(stcls)
        gold_state = gold_.c
        self.set_valid(is_valid, stcls.c)
        cdef int n_gold = 0
        for i in range(self.n_moves):
            if is_valid[i]:
                costs[i] = self.c[i].get_cost(stcls, &gold_state, self.c[i].label)
                if costs[i] <= 0:
                    n_gold += 1
            else:
                costs[i] = 9000
        if n_gold < 1:
            raise ValueError

    def get_oracle_sequence_from_state(self, StateClass state, ArcEagerGold gold, _debug=None):
        cdef int i
        cdef Pool mem = Pool()
        # n_moves should not be zero at this point, but make sure to avoid zero-length mem alloc
        assert self.n_moves > 0
        costs = <float*>mem.alloc(self.n_moves, sizeof(float))
        is_valid = <int*>mem.alloc(self.n_moves, sizeof(int))

        history = []
        debug_log = []
        failed = False
        while not state.is_final():
            try:
                self.set_costs(is_valid, costs, state, gold)
            except ValueError:
                failed = True
                break
            for i in range(self.n_moves):
                if is_valid[i] and costs[i] <= 0:
                    action = self.c[i]
                    history.append(i)
                    s0 = state.S(0)
                    b0 = state.B(0)
                    if _debug:
                        example = _debug
                        debug_log.append(" ".join((
                            self.get_class_name(i),
                            "S0=", (example.x[s0].text if s0 >= 0 else "__"),
                            "B0=", (example.x[b0].text if b0 >= 0 else "__"),
                            "S0 head?", str(state.has_head(state.S(0))),
                        )))
                        print(debug_log[-1])
                    print("Do action", self.get_class_name(i))
                    action.do(state.c, action.label)
                    print("Done")
                    break
            else:
                failed = False
                break
        if failed:
            example = _debug
            print("Actions")
            for i in range(self.n_moves):
                print(self.get_class_name(i))
            print("Gold")
            for token in example.y:
                print(token.i, token.text, token.dep_, token.head.text)
            aligned_heads, aligned_labels = example.get_aligned_parse()
            print("Aligned heads")
            for i, head in enumerate(aligned_heads):
                print(example.x[i], example.x[head] if head is not None else "__")

            print("Predicted tokens")
            print([(w.i, w.text) for w in example.x])
            s0 = state.S(0)
            b0 = state.B(0)
            debug_log.append(" ".join((
                "?",
                "S0=", (example.x[s0].text if s0 >= 0 else "-"),
                "B0=", (example.x[b0].text if b0 >= 0 else "-"),
                "S0 head?", str(state.has_head(state.S(0))),
            )))
            s0 = state.S(0)
            b0 = state.B(0)
            print("\n".join(debug_log))
            print("Arc is gold B0, S0?", arc_is_gold(&gold.c, b0, s0))
            print("Arc is gold S0, B0?", arc_is_gold(&gold.c, s0, b0))
            print("is_head_unknown(s0)", is_head_unknown(&gold.c, s0))
            print("is_head_unknown(b0)", is_head_unknown(&gold.c, b0))
            print("b0", b0, "gold.heads[s0]", gold.c.heads[s0])
            print("Stack", [example.x[i] for i in state.stack])
            print("Buffer", [example.x[i] for i in state.queue])
            raise ValueError(Errors.E024)
        return history
