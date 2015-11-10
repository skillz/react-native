/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "RCTShadowText.h"

#import "RCTAccessibilityManager.h"
#import "RCTUIManager.h"
#import "RCTBridge.h"
#import "RCTConvert.h"
#import "RCTImageComponent.h"
#import "RCTLog.h"
#import "RCTShadowRawText.h"
#import "RCTSparseArray.h"
#import "RCTText.h"
#import "RCTUtils.h"

CGFloat const RCTTextAutoSizeDefaultMinimumFontScale       = 0.5f;
CGFloat const RCTTextAutoSizeWidthErrorMargin              = 0.05f;
CGFloat const RCTTextAutoSizeGranularity                   = 0.001f;

NSString *const RCTIsHighlightedAttributeName              = @"IsHighlightedAttributeName";
NSString *const RCTReactTagAttributeName                   = @"ReactTagAttributeName";

@implementation RCTShadowText
{
  NSTextStorage *_cachedTextStorage;
  CGFloat _cachedTextStorageWidth;
  NSAttributedString *_cachedAttributedString;
  CGFloat _effectiveLetterSpacing;
}

static css_dim_t RCTMeasure(void *context, float width)
{
  RCTShadowText *shadowText = (__bridge RCTShadowText *)context;
  NSTextStorage *textStorage = [shadowText buildTextStorageForWidth:width];
  NSLayoutManager *layoutManager = textStorage.layoutManagers.firstObject;
  NSTextContainer *textContainer = layoutManager.textContainers.firstObject;
  CGSize computedSize = [layoutManager usedRectForTextContainer:textContainer].size;

  css_dim_t result;
  result.dimensions[CSS_WIDTH] = RCTCeilPixelValue(computedSize.width);
  if (shadowText->_effectiveLetterSpacing < 0) {
    result.dimensions[CSS_WIDTH] -= shadowText->_effectiveLetterSpacing;
  }
  result.dimensions[CSS_HEIGHT] = RCTCeilPixelValue(computedSize.height);
  return result;
}

- (instancetype)init
{
  if ((self = [super init])) {
    _fontSize = NAN;
    _letterSpacing = NAN;
    _isHighlighted = NO;
    _textDecorationStyle = NSUnderlineStyleSingle;
    _opacity = 1.0;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(contentSizeMultiplierDidChange:)
                                                 name:RCTUIManagerWillUpdateViewsDueToContentSizeMultiplierChangeNotification
                                               object:nil];
  }
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSString *)description
{
  NSString *superDescription = super.description;
  return [[superDescription substringToIndex:superDescription.length - 1] stringByAppendingFormat:@"; text: %@>", [self attributedString].string];
}

- (void)contentSizeMultiplierDidChange:(NSNotification *)note
{
  [self dirtyLayout];
  [self dirtyText];
}

- (NSDictionary *)processUpdatedProperties:(NSMutableSet<RCTApplierBlock> *)applierBlocks
                          parentProperties:(NSDictionary *)parentProperties
{
  parentProperties = [super processUpdatedProperties:applierBlocks
                                    parentProperties:parentProperties];

  UIEdgeInsets padding = self.paddingAsInsets;
  CGFloat width = self.frame.size.width - (padding.left + padding.right);
  
  NSTextStorage *textStorage = [self buildTextStorageForWidth:width];
  CGRect textFrame = [self calculateTextFrame:textStorage];
  [applierBlocks addObject:^(RCTSparseArray *viewRegistry) {
    RCTText *view = viewRegistry[self.reactTag];
    view.textFrame = textFrame;
    view.textStorage = textStorage;
  }];

  return parentProperties;
}

- (void)applyLayoutNode:(css_node_t *)node
      viewsWithNewFrame:(NSMutableSet<RCTShadowView *> *)viewsWithNewFrame
       absolutePosition:(CGPoint)absolutePosition
{
  [super applyLayoutNode:node viewsWithNewFrame:viewsWithNewFrame absolutePosition:absolutePosition];
  [self dirtyPropagation];
}

- (NSTextStorage *)buildTextStorageForWidth:(CGFloat)width
{
  if (_cachedTextStorage && width == _cachedTextStorageWidth) {
    return _cachedTextStorage;
  }

  NSLayoutManager *layoutManager = [NSLayoutManager new];

  NSTextStorage *textStorage = [[NSTextStorage alloc] initWithAttributedString:self.attributedString];
  [textStorage addLayoutManager:layoutManager];

  NSTextContainer *textContainer = [NSTextContainer new];
  textContainer.lineFragmentPadding = 0.0;
  textContainer.lineBreakMode = _numberOfLines > 0 ? NSLineBreakByTruncatingTail : NSLineBreakByClipping;
  textContainer.maximumNumberOfLines = _numberOfLines;
  textContainer.size = (CGSize){isnan(width) ? CGFLOAT_MAX : width, CGFLOAT_MAX};

  [layoutManager addTextContainer:textContainer];
  [layoutManager ensureLayoutForTextContainer:textContainer];

  _cachedTextStorageWidth = width;
  _cachedTextStorage = textStorage;

  return textStorage;
}

- (void)dirtyText
{
  [super dirtyText];
  _cachedTextStorage = nil;
}

- (void)recomputeText
{
  [self attributedString];
  [self setTextComputed];
  [self dirtyPropagation];
}

- (NSAttributedString *)attributedString
{
  return [self _attributedStringWithFontFamily:nil
                                      fontSize:nil
                                    fontWeight:nil
                                     fontStyle:nil
                                 letterSpacing:nil
                            useBackgroundColor:NO
                               foregroundColor:self.color ?: [UIColor blackColor]
                               backgroundColor:self.backgroundColor
                                       opacity:self.opacity];
}

- (NSAttributedString *)_attributedStringWithFontFamily:(NSString *)fontFamily
                                               fontSize:(NSNumber *)fontSize
                                             fontWeight:(NSString *)fontWeight
                                              fontStyle:(NSString *)fontStyle
                                          letterSpacing:(NSNumber *)letterSpacing
                                     useBackgroundColor:(BOOL)useBackgroundColor
                                        foregroundColor:(UIColor *)foregroundColor
                                        backgroundColor:(UIColor *)backgroundColor
                                                opacity:(CGFloat)opacity
{
  if (![self isTextDirty] && _cachedAttributedString) {
    return _cachedAttributedString;
  }

  if (_fontSize && !isnan(_fontSize)) {
    fontSize = @(_fontSize);
  }
  if (_fontWeight) {
    fontWeight = _fontWeight;
  }
  if (_fontStyle) {
    fontStyle = _fontStyle;
  }
  if (_fontFamily) {
    fontFamily = _fontFamily;
  }
  if (!isnan(_letterSpacing)) {
    letterSpacing = @(_letterSpacing);
  }

  _effectiveLetterSpacing = letterSpacing.doubleValue;

  NSMutableAttributedString *attributedString = [NSMutableAttributedString new];
  for (RCTShadowView *child in [self reactSubviews]) {
    if ([child isKindOfClass:[RCTShadowText class]]) {
      RCTShadowText *shadowText = (RCTShadowText *)child;
      [attributedString appendAttributedString:
        [shadowText _attributedStringWithFontFamily:fontFamily
                                           fontSize:fontSize
                                         fontWeight:fontWeight
                                          fontStyle:fontStyle
                                      letterSpacing:letterSpacing
                                 useBackgroundColor:YES
                                    foregroundColor:shadowText.color ?: foregroundColor
                                    backgroundColor:shadowText.backgroundColor ?: backgroundColor
                                            opacity:opacity * shadowText.opacity]];
    } else if ([child isKindOfClass:[RCTShadowRawText class]]) {
      RCTShadowRawText *shadowRawText = (RCTShadowRawText *)child;
      [attributedString appendAttributedString:[[NSAttributedString alloc] initWithString:shadowRawText.text ?: @""]];
    } else if ([child conformsToProtocol:@protocol(RCTImageComponent)]) {
      UIImage *image = ((id<RCTImageComponent>)child).image;
      if (image) {
        NSTextAttachment *imageAttachment = [NSTextAttachment new];
        imageAttachment.image = image;
        [attributedString appendAttributedString:[NSAttributedString attributedStringWithAttachment:imageAttachment]];
      } else {
        //TODO: add placeholder image?
      }
    } else {
      RCTLogError(@"<Text> can't have any children except <Text>, <Image> or raw strings");
    }

    [child setTextComputed];
  }

  [self _addAttribute:NSForegroundColorAttributeName
            withValue:[foregroundColor colorWithAlphaComponent:CGColorGetAlpha(foregroundColor.CGColor) * opacity]
   toAttributedString:attributedString];

  if (_isHighlighted) {
    [self _addAttribute:RCTIsHighlightedAttributeName withValue:@YES toAttributedString:attributedString];
  }
  if (useBackgroundColor && backgroundColor) {
    [self _addAttribute:NSBackgroundColorAttributeName
              withValue:[backgroundColor colorWithAlphaComponent:CGColorGetAlpha(backgroundColor.CGColor) * opacity]
     toAttributedString:attributedString];
  }

  UIFont *font = [RCTConvert UIFont:nil withFamily:fontFamily
                               size:fontSize weight:fontWeight style:fontStyle
                    scaleMultiplier:(_allowFontScaling && _fontSizeMultiplier > 0.0 ? _fontSizeMultiplier : 1.0)];
  [self _addAttribute:NSFontAttributeName withValue:font toAttributedString:attributedString];
  [self _addAttribute:NSKernAttributeName withValue:letterSpacing toAttributedString:attributedString];
  [self _addAttribute:RCTReactTagAttributeName withValue:self.reactTag toAttributedString:attributedString];
  [self _setParagraphStyleOnAttributedString:attributedString];

  // create a non-mutable attributedString for use by the Text system which avoids copies down the line
  _cachedAttributedString = [[NSAttributedString alloc] initWithAttributedString:attributedString];
  [self dirtyLayout];

  return _cachedAttributedString;
}

- (void)_addAttribute:(NSString *)attribute withValue:(id)attributeValue toAttributedString:(NSMutableAttributedString *)attributedString
{
  [attributedString enumerateAttribute:attribute inRange:NSMakeRange(0, attributedString.length) options:0 usingBlock:^(id value, NSRange range, BOOL *stop) {
    if (!value && attributeValue) {
      [attributedString addAttribute:attribute value:attributeValue range:range];
    }
  }];
}

/*
 * LineHeight works the same way line-height works in the web: if children and self have
 * varying lineHeights, we simply take the max.
 */
- (void)_setParagraphStyleOnAttributedString:(NSMutableAttributedString *)attributedString
{
  // check if we have lineHeight set on self
  __block BOOL hasParagraphStyle = NO;
  if (_lineHeight || _textAlign) {
    hasParagraphStyle = YES;
  }

  if (!_lineHeight) {
    self.lineHeight = 0.0;
  }

  // check for lineHeight on each of our children, update the max as we go (in self.lineHeight)
  [attributedString enumerateAttribute:NSParagraphStyleAttributeName inRange:(NSRange){0, attributedString.length} options:0 usingBlock:^(id value, NSRange range, BOOL *stop) {
    if (value) {
      NSParagraphStyle *paragraphStyle = (NSParagraphStyle *)value;
      CGFloat maximumLineHeight = round(paragraphStyle.maximumLineHeight / self.fontSizeMultiplier);
      if (maximumLineHeight > self.lineHeight) {
        self.lineHeight = maximumLineHeight;
      }
      hasParagraphStyle = YES;
    }
  }];

  self.textAlign = _textAlign ?: NSTextAlignmentNatural;
  self.writingDirection = _writingDirection ?: NSWritingDirectionNatural;

  // if we found anything, set it :D
  if (hasParagraphStyle) {
    NSMutableParagraphStyle *paragraphStyle = [NSMutableParagraphStyle new];
    paragraphStyle.alignment = _textAlign;
    paragraphStyle.baseWritingDirection = _writingDirection;
    CGFloat lineHeight = round(_lineHeight * (_allowFontScaling && self.fontSizeMultiplier > 0.0 ? self.fontSizeMultiplier : 1.0));
    paragraphStyle.minimumLineHeight = lineHeight;
    paragraphStyle.maximumLineHeight = lineHeight;
    [attributedString addAttribute:NSParagraphStyleAttributeName
                             value:paragraphStyle
                             range:(NSRange){0, attributedString.length}];
  }

  // Text decoration
  if(_textDecorationLine == RCTTextDecorationLineTypeUnderline ||
     _textDecorationLine == RCTTextDecorationLineTypeUnderlineStrikethrough) {
    [self _addAttribute:NSUnderlineStyleAttributeName withValue:@(_textDecorationStyle)
     toAttributedString:attributedString];
  }
  if(_textDecorationLine == RCTTextDecorationLineTypeStrikethrough ||
     _textDecorationLine == RCTTextDecorationLineTypeUnderlineStrikethrough){
    [self _addAttribute:NSStrikethroughStyleAttributeName withValue:@(_textDecorationStyle)
     toAttributedString:attributedString];
  }
  if(_textDecorationColor) {
    [self _addAttribute:NSStrikethroughColorAttributeName withValue:_textDecorationColor
     toAttributedString:attributedString];
    [self _addAttribute:NSUnderlineColorAttributeName withValue:_textDecorationColor
     toAttributedString:attributedString];
  }
}

#pragma mark Autosizing

- (CGRect)calculateTextFrame:(NSTextStorage *)textStorage
{
  CGRect textFrame = UIEdgeInsetsInsetRect((CGRect){CGPointZero, self.frame.size},
                                           self.paddingAsInsets);

  if (_adjustsFontSizeToFit) {
    textFrame = [self updateStorage:textStorage toFitFrame:textFrame];
  }

  return textFrame;
}

- (CGRect)updateStorage:(NSTextStorage *)textStorage toFitFrame:(CGRect)frame
{

  BOOL fits = [self attemptScale:1.0f
                       inStorage:textStorage
                        forFrame:frame];
  CGSize requiredSize;
  if (!fits) {
    requiredSize = [self calculateOptimumScaleInFrame:frame
                                           forStorage:textStorage
                                             minScale:self.minimumFontScale
                                             maxScale:1.0
                                              prevMid:INT_MAX];
  } else {
    requiredSize = [self calculateSize:textStorage];
  }

  //Vertically center draw position
  frame.origin.y = self.paddingAsInsets.top + RCTRoundPixelValue((CGRectGetHeight(frame) - requiredSize.height) / 2.0f);
  return frame;
}

- (CGSize)calculateOptimumScaleInFrame:(CGRect)frame
                            forStorage:(NSTextStorage *)textStorage
                              minScale:(CGFloat)minScale
                              maxScale:(CGFloat)maxScale
                               prevMid:(CGFloat)prevMid
{
  CGFloat midScale = (minScale + maxScale) / 2.0f;
  if (round((prevMid / RCTTextAutoSizeGranularity)) == round((midScale / RCTTextAutoSizeGranularity))) {
    //Bail because we can't meet error margin.
    return [self calculateSize:textStorage];
  } else {
    RCTSizeComparison comparison = [self attemptScale:midScale
                                            inStorage:textStorage
                                             forFrame:frame];
    if (comparison == RCTSizeWithinRange) {
      return [self calculateSize:textStorage];
    } else if (comparison == RCTSizeTooLarge) {
      return [self calculateOptimumScaleInFrame:frame
                                     forStorage:textStorage
                                       minScale:minScale
                                       maxScale:midScale - RCTTextAutoSizeGranularity
                                        prevMid:midScale];
    } else {
      return [self calculateOptimumScaleInFrame:frame
                                     forStorage:textStorage
                                       minScale:midScale + RCTTextAutoSizeGranularity
                                       maxScale:maxScale
                                        prevMid:midScale];
    }
  }
}

- (RCTSizeComparison)attemptScale:(CGFloat)scale
                        inStorage:(NSTextStorage *)textStorage
                         forFrame:(CGRect)frame
{
  NSLayoutManager *layoutManager = [textStorage.layoutManagers firstObject];
  NSTextContainer *textContainer = [layoutManager.textContainers firstObject];

  NSRange glyphRange = NSMakeRange(0, textStorage.length);
  [textStorage beginEditing];
  [textStorage enumerateAttribute:NSFontAttributeName
                           inRange:glyphRange
                           options:0
                        usingBlock:^(UIFont *font, NSRange range, BOOL *stop)
   {
     if (font) {
       UIFont *originalFont = [self.attributedString attribute:NSFontAttributeName
                                                       atIndex:range.location
                                                effectiveRange:&range];
       UIFont *newFont = [font fontWithSize:originalFont.pointSize * scale];
       [textStorage removeAttribute:NSFontAttributeName range:range];
       [textStorage addAttribute:NSFontAttributeName value:newFont range:range];
     }
   }];

  [textStorage endEditing];

  NSInteger linesRequired = [self numberOfLinesRequired:[textStorage.layoutManagers firstObject]];
  CGSize requiredSize = [self calculateSize:textStorage];

  BOOL fitSize = requiredSize.height <= CGRectGetHeight(frame) &&
  requiredSize.width <= CGRectGetWidth(frame);

  BOOL fitLines = linesRequired <= textContainer.maximumNumberOfLines ||
  textContainer.maximumNumberOfLines == 0;

  if (fitLines && fitSize) {
    if ((requiredSize.width + (CGRectGetWidth(frame) * RCTTextAutoSizeWidthErrorMargin)) > CGRectGetWidth(frame))
    {
      return RCTSizeWithinRange;
    } else {
      return RCTSizeTooSmall;
    }
  } else {
    return RCTSizeTooLarge;
  }
}

// Via Apple Text Layout Programming Guide
// https://developer.apple.com/library/mac/documentation/Cocoa/Conceptual/TextLayout/Tasks/CountLines.html
- (NSInteger)numberOfLinesRequired:(NSLayoutManager *)layoutManager
{
  NSInteger numberOfLines, index, numberOfGlyphs = [layoutManager numberOfGlyphs];
  NSRange lineRange;
  for (numberOfLines = 0, index = 0; index < numberOfGlyphs; numberOfLines++){
    (void) [layoutManager lineFragmentRectForGlyphAtIndex:index
                                           effectiveRange:&lineRange];
    index = NSMaxRange(lineRange);
  }

  return numberOfLines;
}

// Via Apple Text Layout Programming Guide
//https://developer.apple.com/library/mac/documentation/Cocoa/Conceptual/TextLayout/Tasks/StringHeight.html
- (CGSize)calculateSize:(NSTextStorage *)storage
{
  NSLayoutManager *layoutManager = [storage.layoutManagers firstObject];
  NSTextContainer *textContainer = [layoutManager.textContainers firstObject];

  [textContainer setLineBreakMode:NSLineBreakByWordWrapping];
  NSInteger maxLines = [textContainer maximumNumberOfLines];
  [textContainer setMaximumNumberOfLines:0];
  (void) [layoutManager glyphRangeForTextContainer:textContainer];
  CGSize requiredSize = [layoutManager usedRectForTextContainer:textContainer].size;
  [textContainer setMaximumNumberOfLines:maxLines];

  return requiredSize;
}


- (void)fillCSSNode:(css_node_t *)node
{
  [super fillCSSNode:node];
  node->measure = RCTMeasure;
  node->children_count = 0;
}

- (void)insertReactSubview:(RCTShadowView *)subview atIndex:(NSInteger)atIndex
{
  [super insertReactSubview:subview atIndex:atIndex];
  self.cssNode->children_count = 0;
}

- (void)removeReactSubview:(RCTShadowView *)subview
{
  [super removeReactSubview:subview];
  self.cssNode->children_count = 0;
}

- (void)setBackgroundColor:(UIColor *)backgroundColor
{
  super.backgroundColor = backgroundColor;
  [self dirtyText];
}

#define RCT_TEXT_PROPERTY(setProp, ivar, type) \
- (void)set##setProp:(type)value;              \
{                                              \
  ivar = value;                                \
  [self dirtyText];                            \
}

RCT_TEXT_PROPERTY(AdjustsFontSizeToFit, _adjustsFontSizeToFit, BOOL)
RCT_TEXT_PROPERTY(Color, _color, UIColor *)
RCT_TEXT_PROPERTY(FontFamily, _fontFamily, NSString *)
RCT_TEXT_PROPERTY(FontSize, _fontSize, CGFloat)
RCT_TEXT_PROPERTY(FontWeight, _fontWeight, NSString *)
RCT_TEXT_PROPERTY(FontStyle, _fontStyle, NSString *)
RCT_TEXT_PROPERTY(IsHighlighted, _isHighlighted, BOOL)
RCT_TEXT_PROPERTY(LetterSpacing, _letterSpacing, CGFloat)
RCT_TEXT_PROPERTY(LineHeight, _lineHeight, CGFloat)
RCT_TEXT_PROPERTY(NumberOfLines, _numberOfLines, NSUInteger)
RCT_TEXT_PROPERTY(ShadowOffset, _shadowOffset, CGSize)
RCT_TEXT_PROPERTY(TextAlign, _textAlign, NSTextAlignment)
RCT_TEXT_PROPERTY(TextDecorationColor, _textDecorationColor, UIColor *)
RCT_TEXT_PROPERTY(TextDecorationLine, _textDecorationLine, RCTTextDecorationLineType)
RCT_TEXT_PROPERTY(TextDecorationStyle, _textDecorationStyle, NSUnderlineStyle)
RCT_TEXT_PROPERTY(WritingDirection, _writingDirection, NSWritingDirection)
RCT_TEXT_PROPERTY(Opacity, _opacity, CGFloat)

- (void)setAllowFontScaling:(BOOL)allowFontScaling
{
  _allowFontScaling = allowFontScaling;
  for (RCTShadowView *child in [self reactSubviews]) {
    if ([child isKindOfClass:[RCTShadowText class]]) {
      ((RCTShadowText *)child).allowFontScaling = allowFontScaling;
    }
  }
  [self dirtyText];
}

- (void)setFontSizeMultiplier:(CGFloat)fontSizeMultiplier
{
  _fontSizeMultiplier = fontSizeMultiplier;
  for (RCTShadowView *child in [self reactSubviews]) {
    if ([child isKindOfClass:[RCTShadowText class]]) {
      ((RCTShadowText *)child).fontSizeMultiplier = fontSizeMultiplier;
    }
  }
  [self dirtyText];
}

- (void)setMinimumFontScale:(CGFloat)minimumFontScale
{
  if (minimumFontScale >= 0.01) {
    _minimumFontScale = minimumFontScale;
  }
  [self dirtyText];
}

@end
